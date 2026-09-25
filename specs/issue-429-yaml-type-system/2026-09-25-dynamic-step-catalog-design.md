# Dynamic Step Catalog — schema-validated YAML step definitions

**Covers:** #433
**Repo:** casehubio/platform
**Depends on:** #429 (ValueType, ParameterType — landed), #432 (ImportExpander — landed)

## Problem

yaml-core provides coordination primitives (state machines, barriers, semaphores, channels). The `@StepPlugin` system provides type-safe step actions with compile-time validation. But adding a new step action requires a Java record, APT compilation, and redeployment.

For FSI operations teams writing playbooks (risk response, trading desk coordination, compliance workflows), every new step action requires a developer. The coordination YAML is operationally editable; the step vocabulary is not.

## Scope

**In scope:** Step definition YAML model, step catalog SPI + composite registry, all 6 invoke binding handlers (MCP, REST, GraphQL, Python, Agent, Process), load-time playbook validation against catalog.

**Out of scope (follow-on):**
- IDE JSON Schema generation Maven plugin (#437)
- LSP-based import resolution (#438)
- StepParameterType / ParameterType convergence evaluation (#439)
- Security model hardening for invoke handlers (#440)

## Design

### Layer 1: Step definition model (yaml-core, zero-dep)

New types in `io.casehub.yaml.core.step`:

#### StepParameterType

Step parameters use their own type enum, separate from `ParameterType`. Module parameters are always string-valued (YAML text parsed via `ParameterType.parse()`). Step parameters describe runtime schemas that include complex types — OBJECT (maps/structures) and ARRAY (ordered collections) — which the module parameter system does not support.

```java
public enum StepParameterType {
    STRING, INTEGER, NUMBER, BOOLEAN, ARRAY, OBJECT;

    public static StepParameterType fromString(String name) {
        return switch (name.toUpperCase(java.util.Locale.ROOT)) {
            case "STRING" -> STRING;
            case "INTEGER" -> INTEGER;
            case "NUMBER", "DECIMAL" -> NUMBER;
            case "BOOLEAN" -> BOOLEAN;
            case "ARRAY" -> ARRAY;
            case "OBJECT" -> OBJECT;
            default -> throw new IllegalArgumentException(
                    "Unknown step parameter type '" + name
                    + "'. Expected: STRING, INTEGER, NUMBER, BOOLEAN, ARRAY, OBJECT.");
        };
    }

    public boolean isScalar() {
        return this != ARRAY && this != OBJECT;
    }
}
```

#### StepDefinitionFile

```java
public record StepDefinitionFile(
        String namespace,
        Map<String, StepDefinition> actions) {

    public StepDefinitionFile {
        if (namespace == null) namespace = "";
        actions = Map.copyOf(actions);
    }
}
```

#### StepDefinition

```java
public record StepDefinition(
        String name,
        String description,
        Map<String, StepParameter> inputs,
        Map<String, StepParameter> outputs,
        InvokeBinding invoke) {

    public StepDefinition {
        if (inputs == null) inputs = Map.of();
        if (outputs == null) outputs = Map.of();
    }

    public String qualifiedName(String namespace) {
        return namespace.isEmpty() ? name : namespace + "." + name;
    }
}
```

#### StepParameter

```java
public record StepParameter(
        StepParameterType type,
        boolean required,
        String defaultValue,
        List<String> allowedValues,
        String format,
        String description) {

    public StepParameter {
        if (type == null) type = StepParameterType.STRING;
        if (allowedValues == null) allowedValues = List.of();
    }
}
```

`defaultValue` is `String` — consistent with `YamlModuleParameter.defaultValue`. Values arrive as YAML text; parsing to the declared type happens at validation time via `StepParameterType`. This avoids YAML parser inference issues where `42` might arrive as `Integer` or `Long` depending on magnitude.

#### InvokeBinding sealed interface

```java
public sealed interface InvokeBinding {

    record Mcp(String tool) implements InvokeBinding {}

    record Rest(String method, String url,
                Map<String, String> headers,
                Map<String, String> body) implements InvokeBinding {
        public Rest {
            if (method == null) method = "GET";
            if (headers == null) headers = Map.of();
            if (body == null) body = Map.of();
        }
    }

    record Graphql(String query) implements InvokeBinding {}

    record Python(String script) implements InvokeBinding {}

    record Agent(String descriptor,
                 String systemPrompt,
                 String model,
                 String timeout,
                 boolean structuredOutput) implements InvokeBinding {
        public Agent {
            if (descriptor == null && systemPrompt == null)
                throw new IllegalArgumentException(
                        "Agent binding requires either descriptor or systemPrompt");
        }
    }

    record Process(String command, List<String> args,
                   String output, String timeout,
                   Map<String, String> env,
                   String workingDir,
                   String onError) implements InvokeBinding {
        public Process {
            if (command == null)
                throw new IllegalArgumentException("Process binding requires command");
            if (args == null) args = List.of();
            if (output == null) output = "json";
            if (env == null) env = Map.of();
            if (onError == null) onError = "stderr";
        }
    }
}
```

These are pure data records — they describe the binding, they don't execute it. Parallel to how `ForEachDirective` describes iteration without executing it.

**Agent binding resolution:** Either `descriptor` or `systemPrompt` must be provided:

- **`descriptor`** — a named reference to a YAML descriptor file loaded from a configurable path (`casehub.steps.agent-descriptors`). The descriptor file contains `systemPrompt`, `model`, `timeout`, and optional `mcpServers`. This is the FSI-preferred path: descriptors are versioned artifacts reviewed alongside step definitions.
- **`systemPrompt`** — inline system prompt for simple agent bindings that don't warrant a separate descriptor file.

The `model` field on InvokeBinding.Agent is an override — it takes precedence over the descriptor's model if both are specified. `timeout` is a duration string (e.g. `30s`, `5m`) parsed at handler creation time.

The handler constructs `userPrompt` at execution time by serializing the step's input parameters as structured JSON: `"Execute with the following inputs: {json}"`. When `structuredOutput: true`, the agent response is parsed as JSON and validated against the step's declared output schema.

#### StepDefinitionParser

```java
public final class StepDefinitionParser {

    public static StepDefinitionFile parse(Map<String, Object> yaml) { ... }

    static StepDefinition parseAction(String name, Map<String, Object> raw) { ... }

    static StepParameter parseParameter(Map<String, Object> raw) { ... }

    static InvokeBinding parseInvoke(Object raw) { ... }
}
```

Pure function, zero dependencies beyond yaml-core. Accepts the parsed YAML map (from Jackson or any YAML parser) and produces the typed model. Validates structural correctness (required fields, valid invoke binding types, valid parameter types).

**Relationship to Jackson deserialization:** Both `StepDefinitionParser` and the Jackson mixins produce the same model types (`StepDefinitionFile`, `StepDefinition`, etc.). Jackson is the primary path for consumers with Jackson on their classpath. `StepDefinitionParser` is the zero-dep fallback — needed because yaml-core must remain zero-dependency. This parallels the existing `YamlModuleFile`/`YamlModuleFileMixin` pattern. Contract tests verify both paths produce identical results for the same input.

#### StepValidator

```java
public final class StepValidator {

    public static List<String> validateStep(
            String actionName,
            Map<String, Object> params,
            StepDefinition definition) { ... }

    public static List<String> validateOutputs(
            Map<String, Object> outputs,
            StepDefinition definition) { ... }
}
```

Load-time and runtime validation. Checks:
- All `required: true` inputs are present in params
- Parameter types match declared types (scalar types validated via parsing; OBJECT validated as `Map`; ARRAY validated as `List`)
- Enum values are within allowedValues
- Output fields match declared output schema

### Layer 2: Step catalog SPI (yaml-step-runtime)

`CatalogEntry` and `StepCatalog` live in yaml-step-runtime — not yaml-plugin-api. This preserves yaml-plugin-api's zero-dependency rule (CLAUDE.md: "yaml-plugin-api/ must remain zero-dependency") and keeps plugin authors' classpath clean. CatalogEntry joins `StepDefinition` (from yaml-core) with `StepAction` (from yaml-plugin-api) — it's an integration type, which belongs in the integration module.

```java
public record CatalogEntry(
        String qualifiedName,
        StepDefinition definition,
        StepAction action) {}
```

```java
public interface StepCatalog {

    Optional<CatalogEntry> resolve(String actionName);

    Set<String> availableActions();
}
```

The catalog SPI is minimal. Consumers resolve actions by name and get both metadata (StepDefinition for schema validation) and execution (StepAction for running the step).

### Layer 3: Invoke handlers (yaml-step-runtime, CDI)

New module `yaml-step-runtime/` with artifact `casehub-platform-yaml-step-runtime`.

Dependencies: yaml-core, yaml-plugin-api, yaml-jackson, jackson-databind, quarkus-arc, platform-api (for AgentProvider, MCP).

#### InvokeHandler SPI

```java
public interface InvokeHandler {

    boolean supports(InvokeBinding binding);

    StepAction create(StepDefinition definition, InvokeBinding binding);
}
```

Each invoke handler converts an `InvokeBinding` (data) into a `StepAction` (executable). The handler factory pattern lets the composite catalog assemble actions from definitions without knowing which binding type is being used.

#### Six invoke handlers

**McpInvokeHandler** — Calls an MCP tool by name via the platform's existing tool infrastructure. Injects the MCP tool manager. Maps step inputs to MCP tool parameters and MCP tool result to step outputs.

**RestInvokeHandler** — HTTP request via `java.net.http.HttpClient`. Variable interpolation in URL, headers, and body from step inputs (`${paramName}`). Response parsed as JSON. Timeout from step definition or default.

**GraphqlInvokeHandler** — Executes a GraphQL query against the application's endpoint. Variable interpolation from step inputs. Uses platform's existing SmallRye GraphQL client. Response mapped to step outputs.

**PythonInvokeHandler** — Subprocess execution of a Python script. Step inputs serialized as JSON to stdin. Step outputs read as JSON from stdout. Timeout enforcement. Error reporting from stderr. No GraalPy — subprocess isolation is portable and secure.

**AgentInvokeHandler** — Dispatches to an LLM agent via `AgentProvider` SPI (already in platform).

Resolution: When `descriptor` is provided, loads the agent descriptor YAML file from the configured agent descriptor path. The descriptor file contains:

```yaml
# agent-descriptors/trade-rationale-analyst.yaml
system-prompt: |
  You are a trade rationale analyst. Given a trade decision and context,
  explain the rationale, identify risk factors, and assess confidence.
model: "tier:FLAGSHIP"
timeout: 60s
```

When `systemPrompt` is provided inline, it is used directly.

**Execution model:**
- Constructs `AgentSessionConfig` with systemPrompt (from descriptor or inline), userPrompt (serialized step inputs as structured JSON), model (from binding override, descriptor, or null for default), and timeout.
- Calls `AgentProvider.invoke(config)` which returns `Multi<AgentEvent>` (reactive stream).
- Blocks via `.collect().asList().await().atMost(timeout)` — safe on virtual threads (the platform's execution model). Must NOT run on the Vert.x event loop.
- Collects `AgentEvent.TextDelta` events into final text. `AgentEvent.InvocationComplete` metadata (cost, usage, timing) is captured and stored in `StepResultStore` as execution metadata.
- `AgentTimeoutException` and `AgentProcessException` map to `StepResult.Failure` with descriptive messages.
- When `structuredOutput: true`, parses the collected text as JSON and validates against the step's declared output schema. Parse failure → `StepResult.Failure`.

**ProcessInvokeHandler** — Runs a CLI command via `ProcessBuilder`. Args with variable interpolation. Output parsing: json (Jackson), csv (CsvParser from yaml-core), lines (split), raw (string). Timeout via `Process.waitFor(timeout)`. Environment variables and working directory. Error construction from stderr or exit code.

#### Trust model

Step definitions are versioned, developer-reviewed artifacts — not arbitrary user input. The trust boundary is deployment access: who can commit step definition files to the repository. This is consistent with how Ansible treats Python modules and how Terraform treats providers.

ProcessInvokeHandler and PythonInvokeHandler execute external code. Their security depends on the same controls that govern any server-side code: code review, CI gates, deployment permissions. Audit logging of step executions (action name, inputs, outputs, timing, invoking principal) is a cross-cutting concern applied by `ValidatingStepAction`.

Further hardening (allow-lists, resource limits, sandboxing) is deferred to #440.

#### Validation-wrapping

Each `StepAction` returned by an invoke handler is wrapped with input/output validation:

```java
class ValidatingStepAction implements StepAction {
    private final StepDefinition definition;
    private final StepAction delegate;

    @Override
    public StepResult execute(Map<String, Object> params, ServiceRegistry services) {
        List<String> inputErrors = StepValidator.validateStep(
                definition.name(), params, definition);
        if (!inputErrors.isEmpty()) {
            return StepResult.failed("Input validation: " + String.join("; ", inputErrors));
        }

        StepResult result = delegate.execute(params, services);

        if (result.isSuccess()) {
            List<String> outputErrors = StepValidator.validateOutputs(
                    result.output(), definition);
            if (!outputErrors.isEmpty()) {
                return StepResult.failed("Output validation: " + String.join("; ", outputErrors));
            }
        }
        return result;
    }
}
```

#### CompositeStepCatalog

```java
@ApplicationScoped
public class CompositeStepCatalog implements StepCatalog {

    private final Map<String, CatalogEntry> entries = new ConcurrentHashMap<>();

    @Override
    public Optional<CatalogEntry> resolve(String actionName) {
        return Optional.ofNullable(entries.get(actionName));
    }

    @Override
    public Set<String> availableActions() {
        return Set.copyOf(entries.keySet());
    }
}
```

**Initialization protocol:** Three catalog sources register entries via CDI `@Observes StartupEvent` with `@Priority` ordering:

1. **YamlStepDefinitionSource** `@Priority(100)` — highest priority. Reads step definition YAML files from configurable paths. Registers qualified and unqualified names. First-write-wins in the ConcurrentHashMap.
2. **AptPluginSource** `@Priority(200)` — scans APT-generated manifests. Does not overwrite entries already registered by YAML source.
3. **McpToolSource** `@Priority(300)` — lowest priority. Auto-discovers MCP tools. Does not overwrite existing entries.

`CompositeStepCatalog` itself is `@Startup` with a `CountDownLatch` that blocks `resolve()` until all three sources have completed registration. Each source calls `latch.countDown()` after registration. `resolve()` calls `latch.await(startupTimeout)` — the latch ensures consumers never see a partially-initialized catalog.

Three catalog sources:

**YamlStepDefinitionSource** — Reads step definition YAML files from configurable paths (`casehub.steps.definition-files`). Parses via `StepDefinitionParser`. For each action, resolves the `InvokeBinding` to a `StepAction` via the `InvokeHandler` registry. Wraps with validation.

**AptPluginSource** — Scans `META-INF/yaml-plugins/*.json` manifests on the classpath (produced by existing `@StepPlugin` APT processor). Loads `StepAction` implementation classes. Reads schema from `META-INF/yaml-plugins/<name>.schema.json` and constructs a synthetic `StepDefinition` from the schema.

**McpToolSource** — Auto-discovers MCP tools registered in the platform's MCP tool registry. Each tool becomes a catalog entry with `InvokeBinding.Mcp(toolName)`. Input schema derived from MCP tool parameter schema. Optional — activated when MCP infrastructure is on classpath.

#### Resolution order

When `action: name` is used in a playbook:

1. Check imported step definition files (namespace-qualified names and local names from imported files)
2. Check `@StepPlugin` registry (APT-generated, classpath-scanned)
3. Check MCP tool registry (runtime-discovered)
4. Fail with descriptive error listing available actions

Namespace prefix (`fsitrading.assess-risk`) disambiguates when multiple sources provide the same bare name.

### Namespace semantics

A step definition file declares a `namespace:` at the top level. Action names are registered both as qualified (`namespace.action-name`) and unqualified (`action-name`). Qualified names always win — if two files both declare `assess-risk` under different namespaces, the qualified names `fsi.assess-risk` and `trading.assess-risk` are unambiguous. The unqualified name `assess-risk` is ambiguous and produces an error at load time.

**MCP tool names** are always registered and resolved as bare names — they are never parsed as namespace-qualified. An MCP tool named `fsi.risk.assess` is registered under the key `fsi.risk.assess` (literal string, dots included). It does not collide with a step definition qualified name `fsi.risk.assess` because MCP is the lowest-priority source: the step definition name resolves first. If only the MCP tool exists, it resolves as a bare-name match in step 3 of the resolution order.

### Playbook integration

Playbooks declare step definition imports:

```yaml
imports:
  - module: regional-pipeline
    as: region
  - steps: trading-steps.yaml    # step definition import
```

A new `steps` field on `YamlImport` (parallel to `module`). `steps` and `module` are mutually exclusive on a single import entry — an import is either a module import or a step definition import. Step imports only use the `steps` field; `as`, `parameters`, `forEach`, and `loop` are ignored (they're module-expansion concerns). `when` is valid on step imports (conditional step loading).

**Mutual exclusivity validation:** `YamlImport`'s compact constructor validates that `steps` and `module` are not both non-null. If both are null, this is also an error (an import must be one or the other).

**Expander filtering:** `ModuleExpander.expand()` and `ModuleExpander.validateImports()` filter the import list at entry, skipping entries where `steps != null`. This is a simple predicate filter:

```java
List<YamlImport> moduleImports = imports.stream()
        .filter(imp -> imp.steps() == null)
        .toList();
```

`ImportExpander.expand()` applies the same filter. Step-import entries are processed separately by the playbook loader's step catalog integration.

**Import-scoped catalog lifecycle:**

When the playbook loader encounters `steps:` imports, it creates an `ImportScopedStepCatalog` — a wrapping `StepCatalog` that checks import-scoped definitions first, then delegates to the application-scoped `CompositeStepCatalog`:

```java
class ImportScopedStepCatalog implements StepCatalog {
    private final Map<String, CatalogEntry> importedEntries;
    private final StepCatalog delegate;

    @Override
    public Optional<CatalogEntry> resolve(String actionName) {
        CatalogEntry imported = importedEntries.get(actionName);
        if (imported != null) return Optional.of(imported);
        return delegate.resolve(actionName);
    }
}
```

- **Created:** at playbook parse time, when imports are resolved
- **Scope:** per playbook execution — each playbook gets its own `ImportScopedStepCatalog` instance
- **Destroyed:** when the playbook execution completes (garbage collected)
- **Concurrency:** two playbooks with different step imports execute independently — no shared mutable state. The `CompositeStepCatalog` singleton is read-only after initialization

`action:` in step declarations resolves against:
1. Import-scoped step definitions (from `steps:` imports in this playbook)
2. Global catalog (YAML sources + APT sources + MCP sources)

### Jackson deserialization (yaml-jackson)

yaml-jackson gains mixins for the new types:

- `StepDefinitionFileMixin` — `@JsonAnySetter` for the actions map (same pattern as `YamlModuleFileMixin`)
- `InvokeBindingDeserializer` — Custom deserializer that inspects the YAML key (`mcp:`, `rest:`, `graphql:`, `python:`, `agent:`, `process:`) and delegates to the appropriate `InvokeBinding` record

### What changes where

| Module | Change |
|--------|--------|
| `yaml-core/` | New `io.casehub.yaml.core.step` package: StepDefinitionFile, StepDefinition, StepParameter, StepParameterType, InvokeBinding, StepDefinitionParser, StepValidator |
| `yaml-core/` | `YamlImport` gains `steps` field with mutual exclusivity validation |
| `yaml-core/` | `ModuleExpander.expand()` and `validateImports()` filter out step-import entries |
| `yaml-core/` | `ImportExpander.expand()` filters out step-import entries |
| `yaml-jackson/` | StepDefinitionFileMixin, InvokeBindingDeserializer |
| `yaml-step-runtime/` | **New module** — CatalogEntry, StepCatalog SPI, CompositeStepCatalog, InvokeHandler SPI, 6 invoke handler implementations, 3 catalog sources (YAML, APT, MCP), ValidatingStepAction wrapper, ImportScopedStepCatalog |

### What does NOT change

- `yaml-plugin-api/` — remains zero-dependency. No new types added.
- `yaml-plugin-processor/` — APT processor is unchanged. It still generates to `META-INF/yaml-plugins/`. The new catalog simply reads what the processor already produces.
- `ModuleExpander` — gains a filter at entry to skip step-import entries; expansion logic unchanged.
- `ForEachExpander` — unchanged; step definitions don't use forEach.
- `ImportExpander` — gains a filter at entry to skip step-import entries; expansion logic unchanged.

## Consumer integration

yaml-core provides the model and validation. yaml-step-runtime provides the catalog SPI and CDI implementation. A consumer (e.g., desiredstate's `YamlGraphRecorder`, or Pages' scenario YAML binding #463) adds yaml-step-runtime as a compile dependency and injects `StepCatalog`:

```java
@Inject StepCatalog catalog;

// In playbook loading:
Optional<CatalogEntry> entry = catalog.resolve("assess-risk");
if (entry.isEmpty()) {
    throw new PlaybookValidationException(
        "Unknown action 'assess-risk'. Available: " + catalog.availableActions());
}

// Load-time validation:
StepValidator.validateStep("assess-risk", params, entry.get().definition());

// Runtime execution:
StepResult result = entry.get().action().execute(params, services);
```

## Relationship to existing components

| Component | Relationship |
|-----------|-------------|
| yaml-core orchestration primitives | Step catalog extends yaml-core — actions execute within ScenarioScope coordination |
| `@StepPlugin` APT | Not replaced — complemented. APT-generated plugins are auto-discovered as catalog entries |
| yaml-core modules (`ModuleExpander`) | Separate concept. Step definitions use `StepParameterType` (not `ParameterType`) and are not modules |
| Pages scenario YAML binding (#463) | Consumer — resolves `action:` references via StepCatalog |
| Platform simulation | Simulated step actions use the same schema. `@SimulationEligible` on invoke targets means step definitions work in simulation without modification |
| MCP tool registry | MCP tools are auto-discoverable catalog entries via McpToolSource |

## Non-goals

- **Inline scripting** — no code embedded in YAML. Scripts are external files.
- **Turing-complete YAML** — step definitions declare schemas and invoke bindings, not logic.
- **Replacing @StepPlugin** — Java plugins remain the compile-time-safe path.
- **IDE schema generation** — deferred follow-on (#437).
- **LSP-based import resolution** — deferred follow-on (#438).
- **StepParameterType / ParameterType convergence** — deferred evaluation (#439).
- **Security hardening for invoke handlers** — deferred follow-on (#440).

## References

- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StepAction.java` — execution contract
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StepResult.java` — result sealed interface
- `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/RegistryEmitter.java` — APT manifest format
- `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/SchemaEmitter.java` — APT schema format
- `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterType.java` — module type enum (not used by step definitions)
- `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleParameter.java` — parameter model (String defaultValue pattern)
- `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlModuleFileMixin.java` — @JsonAnySetter pattern for dynamic YAML sections
- GitHub #433, #429, #432, #437, #438, #439, #440, casehubio/casehub-pages#463
