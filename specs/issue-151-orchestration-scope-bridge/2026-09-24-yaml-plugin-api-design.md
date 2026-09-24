# yaml-core Plugin API — Design Spec

**Date:** 2026-09-24
**Status:** Draft

## Problem

yaml-core's YAML-addressable constructs (steps, loops, retries, conditions) are hand-coded with manual parameter extraction, no schema validation, and no extensibility story. Adding a new construct requires deep yaml-core knowledge. Community contributions are impractical.

Current pain points:
- Every primitive does manual `params.getString("url")` with null checks — boilerplate, error-prone, no type safety
- No JSON Schema for YAML validation — errors surface at runtime as NPEs, not at parse time with source locations
- Adding a new step type requires implementing `StepPrimitive`, manual `PrimitiveRegistry.register()`, hand-writing schema
- Loop/retry/forEach are sealed data types interpreted by the executor — not extensible

## Goal

Make the entire yaml-core YAML language expressible as a series of plugins. yaml-core becomes a thin generic runtime engine that loads plugins and dispatches. Plugin authors write an annotated Java record and the framework handles schema generation, YAML registration, typed binding, and invocation.

**Hard constraints:**
1. No performance regression vs current hard-coded constructs
2. The resulting YAML schema must remain clean and usable — no complexity increase for YAML authors
3. Type safety at every level: plugin author (compile-time), YAML author (parse-time), runtime (binding)

## Design

### Plugin types

Three annotations, each with a clear contract:

```java
@StepPlugin("process-execute")
public record ProcessExecuteSpec(
    @Required String command,
    @Optional List<String> args,
    @Optional String workingDir,
    @Optional Duration timeout,
    @Optional boolean mergeStderr
) {
    @Execute
    public StepResult run(ProcessExecutor executor) {
        ProcessResult result = executor.execute(
            new ProcessCommand(command, args, workingDir, timeout, mergeStderr));
        return StepResult.of(Map.of(
            "exitCode", result.exitCode(),
            "stdout", result.stdout()));
    }
}
```

```java
@FlowPlugin("retry")
public record RetrySpec(
    @Optional int maxAttempts,
    @Optional Duration backoff,
    List<PluginInvocation> body
) {
    @Execute
    public StepResult run(PluginExecutor executor) {
        for (int i = 0; i <= maxAttempts; i++) {
            StepResult result = executor.executeAll(body);
            if (result.isSuccess()) return result;
            if (i < maxAttempts) Thread.sleep(backoff.toMillis());
        }
        return StepResult.failed("exhausted retries after " + maxAttempts + " attempts");
    }
}
```

```java
@ConditionPlugin("and")
public record AndCondition(
    List<PluginInvocation> conditions
) {
    @Execute
    public boolean evaluate(PluginExecutor executor) {
        for (PluginInvocation cond : conditions) {
            if (!executor.evaluateCondition(cond)) return false;
        }
        return true;
    }
}
```

| Annotation | Return type | Has children | Use case |
|---|---|---|---|
| `@StepPlugin("name")` | `StepResult` | No | Leaf actions: rest-call, assert, process-execute |
| `@FlowPlugin("name")` | `StepResult` | Yes (`List<PluginInvocation> body`) | Control flow: loop, retry, forEach, parallel |
| `@ConditionPlugin("name")` | `boolean` | Optional (`List<PluginInvocation>`) | Predicates: and, or, not, xor, always, never |

### Module structure

**`yaml-plugin-api`** — zero-dep annotation + SPI module

```
io.casehub.yaml.plugin.api
  @StepPlugin          — name, description
  @FlowPlugin          — name, description
  @ConditionPlugin     — name, description
  @Execute             — marks the execution method
  @Required            — field is required in YAML
  @Optional            — field is optional (has default)
  StepResult           — execution result (exists today, moves here or stays)
  PluginInvocation     — represents a child construct reference in YAML
  PluginExecutor       — runs child constructs (injected into flow/condition execute methods)
  ServiceRegistry      — framework-neutral service lookup (used by generated binders)
```

Plugin authors depend only on this module. No yaml-core, no schema-generator, no CDI, no Spring.

**`yaml-plugin-processor`** — APT (Maven plugin packaging, build-time only)

Depends on: yaml-plugin-api, schema-generator

Generates per plugin:
1. **JSON Schema** — from record fields via PlatformSchemaGenerator, customised with ShorthandModule for YAML-friendly patterns
2. **Typed binder** — generated class that reads from a validated tree (Map) and constructs the record. No Jackson ObjectMapper. Full control over error messages: `"process-execute: 'command' is required (line 42)"`
3. **Registry entry** — plugin name → binder + schema + metadata. Written to `META-INF/yaml-plugins/<name>.json`
4. **Compile-time validation:**
   - Plugin class has exactly one `@Execute` method
   - `@Execute` return type matches annotation type (StepResult for Step/Flow, boolean for Condition)
   - `@FlowPlugin` class has a `List<PluginInvocation>` field
   - Field types are schema-representable (String, int, long, boolean, Duration, List, Map, enums, nested records)
   - Service parameters on `@Execute` are known SPI types

### Service injection

The `@Execute` method's parameters are service dependencies resolved at runtime:

```java
@Execute
public StepResult run(ProcessExecutor executor, CredentialResolver credentials) { ... }
```

The APT inspects parameter types and generates binder code that looks up each service from `ServiceRegistry`:

```java
// Generated binder (simplified)
public StepResult invoke(Map<String, Object> validatedParams, ServiceRegistry services) {
    var spec = new ProcessExecuteSpec(
        (String) validatedParams.get("command"),
        (List<String>) validatedParams.getOrDefault("args", List.of()),
        ...);
    return spec.run(
        services.lookup(ProcessExecutor.class),
        services.lookup(CredentialResolver.class));
}
```

Plugin classes stay framework-neutral. The host runtime (Quarkus, Spring, or standalone) populates the `ServiceRegistry` from its DI container.

### Runtime dispatch

**yaml-core's runtime engine** loads plugins at startup:

1. Scan `META-INF/yaml-plugins/*.json` from classpath
2. Build plugin registry: name → (schema, binder, type)
3. Compose JSON Schema from all registered plugins → the full YAML language schema
4. On YAML parse:
   a. Parse YAML text → tree (Jackson YAML parser)
   b. Validate tree against composed schema (source-located errors)
   c. Walk tree, dispatch each construct to its plugin's generated binder
   d. Binder constructs typed record, resolves services, calls `@Execute`

Plugin lookup is a `HashMap.get()`. Binder invocation is a direct method call on generated code. No reflection at runtime.

### Schema composition

The full YAML language schema is composed from individual plugin schemas at startup:

- Each step plugin contributes a `properties` entry under the `steps` array items
- Each flow plugin contributes similarly, with its `body` field generating a recursive `steps` reference
- Each condition plugin contributes under `conditions`

The composed schema is identical in structure to what a hand-written schema would look like. YAML authors see the same autocomplete, the same validation. The difference is invisible — the schema is assembled from plugins rather than hand-maintained.

ShorthandModule handles scalar-or-object patterns:
```yaml
# Both valid for a timeout field:
timeout: 30s
timeout:
  value: 30
  unit: seconds
```

### Error reporting

**Compile time** (plugin author mistakes):

```
ERROR: @StepPlugin 'process-execute': @Execute method must return StepResult, found void
ERROR: @FlowPlugin 'retry': missing required List<PluginInvocation> field
ERROR: @StepPlugin 'my-step': field type Thread is not schema-representable
```

**Runtime — parse time** (YAML author mistakes):

```
process-execute (line 42, col 5): 'command' is required
retry (line 58, col 3): 'maxAttempts' must be a positive integer, got 'abc'
loop (line 71, col 3): unknown property 'cound' — did you mean 'count'?
```

**Runtime — execution time** (plugin failures):

```
process-execute (line 42): command 'deploy.sh' failed with exit code 1
  stdout: [captured output]
  stderr: [captured error]
retry (line 58): exhausted retries after 3 attempts
  last failure: rest-call (line 60): HTTP 503 Service Unavailable
```

### Migration path

Existing constructs migrate incrementally:

| Current | Plugin form | Priority |
|---|---|---|
| RestCallPrimitive | `@StepPlugin("rest-call")` | P1 — proof case |
| AssertPrimitive | `@StepPlugin("assert")` | P1 |
| ProcessExecutor | `@StepPlugin("process-execute")` | P1 — new |
| JsonExtractPrimitive | `@StepPlugin("json-extract")` | P2 |
| CompareStatePrimitive | `@StepPlugin("compare-state")` | P2 |
| LoopDirective | `@FlowPlugin("loop")` | P2 |
| RetryDirective | `@FlowPlugin("retry")` | P2 |
| ForEachExpander | `@FlowPlugin("for-each")` | P3 |
| CompoundStepDef | `@FlowPlugin("compound")` | P3 |
| Condition.and/or/not/xor | `@ConditionPlugin("and/or/not/xor")` | P3 |
| ComputeBlock | `@StepPlugin("compute")` | P3 |

The old `StepPrimitive` interface and `PrimitiveRegistry` remain as a compatibility layer during migration. The plugin registry can wrap legacy primitives as plugins (adapter pattern). Once all constructs are migrated, the old interfaces are removed.

### What stays hand-written in yaml-core

These are runtime infrastructure that plugins USE, not YAML-addressable constructs:

- **Variable resolution** — VariableResolver, VariableSource (plugins reference `${var}`)
- **Orchestration primitives** — ScenarioScope, OrcSemaphore, OrcChannel, etc. (runtime coordination)
- **Module system** — YamlModule, ModuleExpander, ModuleBridge (structural composition)
- **Plugin dispatch engine** — registry, schema compositor, tree walker
- **EventRouter, SpeedMultiplier, DurationParser** — utilities

## Out of scope

- Specific plugin implementations (those are the migration tasks)
- Quarkus/Spring integration for ServiceRegistry population (CDI bridge, Spring autoconfiguration)
- IDE plugin for YAML schema autocomplete (uses the composed schema, but IDE tooling is separate)
- ProcessExecutor SPI design (already landed in platform-api)

## References

- `yaml-core/.../orchestration/ScenarioScope.java` — orchestration primitives (stays hand-written)
- `yaml-core/.../orchestration/LoopDirective.java` — example migration candidate
- `yaml-core/.../orchestration/RetryDirective.java` — example migration candidate
- `desiredstate/plugin/` — prior art for YAML plugin model (heavier, reconciliation-focused)
- `desiredstate/annotations/` — prior art for APT + deployment split
- `platform/schema-generator/` — PlatformSchemaGenerator, ShorthandModule (reused for schema generation)
- `platform/yaml-codegen/` — MappingConfig patterns (prior art for schema customisation)
- `platform/graphql-generator/` — APT prior art in platform
- `platform/simulation-generator/` — APT prior art for @SimulationEligible annotation processing
- `platform/platform-api/.../process/ProcessExecutor.java` — first consumer (proof case)
