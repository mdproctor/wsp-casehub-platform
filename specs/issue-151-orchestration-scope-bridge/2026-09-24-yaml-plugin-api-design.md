# yaml-core Step Action Plugin API — Design Spec

**Date:** 2026-09-24
**Status:** Draft (Revised — Round 1)

## Problem

yaml-core's step actions (what a step DOES: rest-call, process-execute, compute, assert) have no extensibility story. Adding a new action type requires deep yaml-core knowledge. There is no JSON Schema for YAML validation of action parameters — errors surface at runtime, not at parse time with source locations. Community contributions of new action types are impractical.

Step actions are an open set — new actions can be added freely without changing the YAML language grammar. This is structurally different from orchestration constructs (loop, retry, forEach, when, timeout, etc.), which are a closed set with fixed composition semantics defined by the decorator evaluation order (issue-386).

**Current state:**
- Action types are not yet implemented as a uniform abstraction — they are planned as part of the orchestration work
- No JSON Schema for action parameter validation
- Structural constructs (`LoopDirective`, `RetryDirective`, `ForEachExpander`, `Condition`, `ComputeBlock`) are correctly modeled as sealed data types and parse-time utilities — not actions

## Goal

Make yaml-core step actions extensible via a plugin model. Plugin authors write an annotated Java record and the framework handles schema generation, YAML registration, typed binding, and invocation.

Structural constructs (decorators) remain the runtime engine's fixed vocabulary — they are not candidates for pluggability. The 13-position decorator evaluation order (issue-386 §Decorator Evaluation Order) is load-bearing for correctness: `timeout` wraps `retry`, `on-error` wraps `timeout`, `semaphore` is inside `retry`, etc. These composition semantics cannot be expressed through a generic plugin execution model.

**Hard constraints:**
1. No performance regression vs hand-coded action dispatch
2. The resulting YAML schema must remain clean and usable — no complexity increase for YAML authors
3. Type safety at every level: plugin author (compile-time), YAML author (parse-time), runtime (binding)

## Design

### Scope boundary — actions vs decorators

| Concern | Model | Extensible? | Example |
|---|---|---|---|
| Step actions (what a step DOES) | `@StepPlugin` | Open set — plugin model | rest-call, process-execute, assert, compute |
| Structural decorators (how steps compose) | Fixed engine vocabulary | Closed set — issue-386 | loop, retry, forEach, when, timeout, delay, on-error, trigger, transform, signal, publish, transition, parallel, semaphore, barrier, quorum, race |
| Conditions (boolean predicates) | `Condition` functional interface + `ConditionEvaluator` + `ExpressionEngine` | Extensible via expression engines (MVEL, JQ) — not via plugins | `when: ${regime} == 'MEAN_REVERTING'` |

Step action plugins execute at **position 10** (the "action" position) in the decorator evaluation order. The plugin receives typed parameters and returns `StepResult`. It has no awareness of the decorator chain wrapping it — decorators are the runtime engine's concern.

### Plugin annotation

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

| Annotation | Return type | Use case |
|---|---|---|
| `@StepPlugin("name")` | `StepResult` | Leaf actions: rest-call, assert, process-execute, compute |

### Module structure

**`yaml-plugin-api`** — zero-dep annotation + SPI module

```
io.casehub.yaml.plugin.api
  @StepPlugin          — name, description
  @Execute             — marks the execution method
  @Required            — field is required in YAML
  @Optional            — field is optional (has default)
  StepResult           — execution result (NEW type — see below)
  ServiceRegistry      — framework-neutral service lookup (interface)
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
   - `@Execute` return type is `StepResult`
   - Field types are schema-representable (String, int, long, boolean, Duration, List, Map, enums, nested records)
   - Service parameters on `@Execute` are known SPI types

### StepResult — new type

`StepResult` is a new sealed interface in `yaml-plugin-api` that provides a typed return value for step action execution. It integrates with the existing `StepResultStore` (which stores results as `Map<String, Object>` via `recordSuccess`/`recordFailure`).

```java
public sealed interface StepResult permits StepResult.Success, StepResult.Failure {

    boolean isSuccess();
    Map<String, Object> output();

    record Success(Map<String, Object> output) implements StepResult {
        public boolean isSuccess() { return true; }
    }

    record Failure(String message) implements StepResult {
        public boolean isSuccess() { return false; }
        public Map<String, Object> output() { return Map.of(); }
    }

    static StepResult of(Map<String, Object> output) { return new Success(output); }
    static StepResult failed(String message) { return new Failure(message); }
}
```

**Integration with StepResultStore:**
- `StepResult.Success` → `StepResultStore.recordSuccess(stepName, result.output())`
- `StepResult.Failure` → `StepResultStore.recordFailure(stepName, new StepError(result.message(), ...))`

This preserves the existing `Map<String, Object>` result model while giving plugin authors a typed API.

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

**ServiceRegistry — framework-neutral by design:**

`ServiceRegistry` is an interface in `yaml-plugin-api`. It is NOT a replacement for CDI — it is a bridge that decouples plugin authors from framework choices. This follows the same pattern as yaml-core's other SPIs (`VariableSource`, `SpeedMultiplier`, `ForEachAdapter`) — interfaces defined at the zero-dep tier, implemented at the integration layer.

```java
public interface ServiceRegistry {
    <T> T lookup(Class<T> serviceType);
}
```

Implementations at the integration layer:
- **Quarkus:** `CdiServiceRegistry` backed by `BeanManager.getReference()` — leverages existing `@DefaultBean` displacement, `@Alternative @Priority(N)` ladder
- **Spring:** `SpringServiceRegistry` backed by `ApplicationContext.getBean()`
- **Standalone/testing:** `MapServiceRegistry` with manual registration

Plugin classes stay framework-neutral. The existing CDI patterns (`@DefaultBean` displacement, `@Alternative @Priority` ladder, test overrides at `@Priority(10+)`) operate at the service implementation level, not at the plugin level.

**What services are available vs engine-internal:**

Step action plugins can request services that are platform SPIs (e.g., `ProcessExecutor`, `CredentialResolver`, `ExpressionEngine`). The following are **engine-internal** and NOT exposed to plugins:
- `ScenarioScope` — orchestration coordination primitives
- `VariableResolver` — variable resolution (the engine resolves `${var}` in YAML parameters BEFORE passing them to the plugin)
- `StepResultStore` — result recording (the engine records results AFTER the plugin returns)
- Decorator evaluation context — the plugin doesn't know its position in the decorator stack

This separation is intentional: the plugin receives resolved, typed parameters and returns a result. The engine handles everything else.

### Runtime dispatch

**yaml-core's runtime engine** loads step action plugins at startup:

1. Scan `META-INF/yaml-plugins/*.json` from classpath
2. Build plugin registry: name → (schema, binder, metadata)
3. Compose JSON Schema from all registered plugins → the step action schema
4. On step execution (position 10 in decorator evaluation order):
   a. Look up action name in plugin registry (`HashMap.get()`)
   b. Binder constructs typed record from resolved YAML parameters
   c. Binder resolves services from ServiceRegistry
   d. Binder calls `@Execute` method → `StepResult`
   e. Engine records result in `StepResultStore`

Plugin lookup is a `HashMap.get()`. Binder invocation is a direct method call on generated code. No reflection at runtime.

### Schema composition

Step action plugin schemas compose into the full YAML language schema:

- Each step plugin contributes a `properties` entry under the `action` discriminator
- The schema includes parameter validation with types, required/optional, and ShorthandModule patterns

The structural portion of the YAML schema (decorators: `loop`, `retry`, `when`, `forEach`, `timeout`, etc.) is hand-written in yaml-core as it is today — these are the engine's fixed vocabulary. The composed schema combines hand-written structural schema + generated action plugin schemas.

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
ERROR: @StepPlugin 'my-step': field type Thread is not schema-representable
ERROR: @StepPlugin 'my-step': no @Execute method found
```

**Runtime — parse time** (YAML author mistakes):

```
process-execute (line 42, col 5): 'command' is required
process-execute (line 43, col 7): 'timeout' must be a duration, got 'abc'
unknown-action (line 50, col 3): unknown action type — registered actions: rest-call, assert, process-execute, compute
```

**Runtime — execution time** (plugin failures):

```
process-execute (line 42): command 'deploy.sh' failed with exit code 1
  stdout: [captured output]
  stderr: [captured error]
```

### Relationship to orchestration decorators (issue-386)

The runtime orchestration spec (issue-386) defines structural constructs as **step decorators** with a strict 13-position evaluation order. These decorators wrap step actions in a fixed nesting stack. Key semantics:

- `timeout` wraps `retry` — the deadline covers the entire retry sequence
- `on-error` wraps `timeout` — timeout exceptions are catchable
- `semaphore` is inside `retry` — permits re-acquired per attempt
- `retry` delegates to `PolicyEnforcer.execute(policy, action)` — existing governance infrastructure

The plugin model does NOT replace or extend this decorator stack. Step action plugins execute at position 10 (the "action" position) within the decorator chain. The plugin receives resolved parameters and returns `StepResult`. It has no awareness of or interaction with the decorator evaluation order.

`LoopDirective`, `RetryDirective`, and `ForEachExpander` remain as they are:
- `LoopDirective` — sealed interface (configuration record parsed from YAML, evaluated by `LoopEvaluator`)
- `RetryDirective` — sealed interface (configuration record parsed from YAML, evaluated by `RetryDecorator` via `PolicyEnforcer`)
- `ForEachExpander` — parse-time utility for collection expansion
- `Condition` — `@FunctionalInterface` with combinator default methods (`and`, `or`, `not`, `xor`), evaluated by `ConditionEvaluator`
- `ComputeBlock` — record with engine + expression, evaluated by the runtime

### Relationship to @ScenarioAction

`@ScenarioAction` (issue-386 §4.3) is the escape hatch for when YAML complexity exceeds the language's comfort zone. It is complementary to `@StepPlugin`, not competing:

| Aspect | `@StepPlugin` | `@ScenarioAction` |
|---|---|---|
| YAML-addressable | Yes — schema generated, parameters from YAML | No — opaque Java method |
| Parameters | Typed fields on record, bound from YAML | `ScenarioContext` — full access to variables, scope, results |
| Schema | Generated JSON Schema for validation + autocomplete | None — action name is just a string key |
| Reusability | High — packaged as library, used across scenarios | Low — typically scenario-specific |
| Use case | Reusable actions: rest-call, process-execute, assert | Complex logic: multi-step orchestration, conditional branching, loops with business logic |

Both execute at position 10 in the decorator evaluation order. The runtime engine treats them identically — the difference is in how they are authored and parameterized.

**Note:** `@ScenarioAction` is not yet implemented. It is a concept defined in issue-386's design philosophy. A tracking issue should be filed for its implementation.

### J2CL compatibility

yaml-core is constrained to be J2CL-compatible (issue-247):
- No `java.lang.reflect`
- No `ConcurrentHashMap`
- No `Thread`, `Lock`, `synchronized`
- No CDI annotations
- No Jackson

`yaml-plugin-api` is a zero-dep module at the same tier as yaml-core. Its types are J2CL-safe:
- `@StepPlugin`, `@Execute`, `@Required`, `@Optional` — annotations (J2CL-safe)
- `StepResult` — sealed interface with records (J2CL-safe)
- `ServiceRegistry` — interface with no implementation (J2CL-safe)

The `yaml-plugin-processor` (APT) is build-time only and does not need to be J2CL-compatible.

The `ServiceRegistry` implementation lives at the integration layer (not in yaml-plugin-api):
- Quarkus: `CdiServiceRegistry` in a Quarkus-specific module (uses CDI `BeanManager`)
- Standalone: `MapServiceRegistry` using `HashMap` (J2CL-safe)

### Module system interaction

yaml-core has a module system (`YamlModule`, `ModuleExpander`, `ModuleBridge`) that provides structural composition of YAML files. Modules are orthogonal to step action plugins:

- The plugin registry is **global** — all registered step action plugins are available to all modules
- A module can reference any registered action type in its steps
- Module-level schema composition uses `$ref` to include plugin-contributed action schemas
- Modules do NOT define their own plugins — plugins are classpath-global, modules are structural composition

Schema validation: when a module `$ref`s a step that uses a plugin-provided action, the composed schema includes the plugin's parameter schema. Unknown action types are caught at schema validation time.

### Migration path

Step action plugins are a new capability. There is no existing uniform action abstraction to migrate FROM — this is greenfield development within an existing framework.

**New step action plugins (this spec):**

| Plugin | Priority | Notes |
|---|---|---|
| `@StepPlugin("rest-call")` | P1 — proof case | New plugin, REST endpoint invocation |
| `@StepPlugin("assert")` | P1 | New plugin, assertion evaluation |
| `@StepPlugin("process-execute")` | P1 | New plugin, subprocess execution. Requires `ProcessExecutor` SPI (not yet defined — see Out of scope) |
| `@StepPlugin("compute")` | P2 | Subsumes `ComputeBlock` (engine + expression). `ComputeBlock` can be kept as an internal model or migrated to a plugin |
| `@StepPlugin("json-extract")` | P2 | New plugin, JSON path extraction |

**Existing types that stay as engine vocabulary (NOT plugins):**

| Type | Role | Why not a plugin |
|---|---|---|
| `LoopDirective` | Sealed config record for loop decorator | Structural — position 3 in decorator stack |
| `RetryDirective` | Sealed config record for retry decorator | Structural — position 7, delegates to PolicyEnforcer |
| `ForEachExpander` | Parse-time collection expansion | Parse-time utility, not a runtime action |
| `Condition` | Functional interface with combinators | Evaluated by ConditionEvaluator, extensible via ExpressionEngine |
| `ComputeBlock` | Record with engine + expression | May migrate to `@StepPlugin("compute")` in P2 |

### What stays hand-written in yaml-core

These are runtime infrastructure that plugins USE, not YAML-addressable constructs:

- **Decorator evaluation order** — the 13-position nesting stack (issue-386)
- **Variable resolution** — VariableResolver, VariableSource, ObjectVariableSource (plugins reference `${var}` — resolved BEFORE plugin invocation)
- **Condition evaluation** — Condition, ConditionEvaluator, Truthiness (extended by ExpressionEngine)
- **Orchestration primitives** — ScenarioScope, OrcSemaphore, OrcChannel, OrcSignal, OrcLatch, OrcStateMachine, OrcCounter, OrcGauge, OrcFlag, OrcMap (runtime coordination)
- **Structural constructs** — LoopDirective, RetryDirective, ForEachExpander, ComputeBlock (sealed config types)
- **Module system** — YamlModule, ModuleExpander, ModuleBridge (structural composition)
- **Plugin dispatch engine** — registry, schema compositor, tree walker
- **EventRouter, SpeedMultiplier, DurationParser** — utilities

## Out of scope

- Specific plugin implementations (those are the development tasks after the framework lands)
- Quarkus/Spring integration for ServiceRegistry population (CDI bridge, Spring autoconfiguration)
- IDE plugin for YAML schema autocomplete (uses the composed schema, but IDE tooling is separate)
- ProcessExecutor SPI design (new SPI to be defined in platform-api — not yet started)
- `@ScenarioAction` mechanism (issue-386 concept, needs its own tracking issue and spec)
- Module system schema composition details (plugin schemas integrate via `$ref`)

## References

- `yaml-core/.../orchestration/ScenarioScope.java` — orchestration primitives (stays hand-written)
- `yaml-core/.../orchestration/LoopDirective.java` — sealed config type (stays as engine vocabulary)
- `yaml-core/.../orchestration/RetryDirective.java` — sealed config type (stays as engine vocabulary)
- `yaml-core/.../orchestration/ComputeBlock.java` — potential P2 migration candidate
- `yaml-core/.../runtime/Condition.java` — functional interface with combinators (stays as-is)
- `yaml-core/.../orchestration/StepResultStore.java` — step result storage (integration point for StepResult)
- `yaml-core/.../orchestration/DefaultScenarioScope.java` — scope implementation (engine-internal)
- `yaml-core/.../resolver/VariableResolver.java` — variable resolution (engine resolves before plugin invocation)
- `yaml-core/.../resolver/ObjectVariableSource.java` — typed variable resolution
- `yaml-core/.../condition/ConditionEvaluator.java` — condition evaluation (engine-internal)
- `desiredstate/plugin/` — prior art for YAML plugin model (heavier, reconciliation-focused)
- `desiredstate/annotations/` — prior art for APT + deployment split
- `platform/schema-generator/` — PlatformSchemaGenerator, ShorthandModule (reused for schema generation)
- `platform/yaml-codegen/` — MappingConfig patterns (prior art for schema customisation)
- `platform/graphql-generator/` — APT prior art in platform
- `platform/simulation-generator/` — APT prior art for @SimulationEligible annotation processing
- `docs/specs/issue-386-runtime-orchestration/2026-09-22-runtime-orchestration-primitives-design.md` — decorator evaluation order, step execution model
- `docs/specs/issue-247-shared-yaml-core/2026-08-29-shared-yaml-core-design.md` — J2CL compatibility constraints
