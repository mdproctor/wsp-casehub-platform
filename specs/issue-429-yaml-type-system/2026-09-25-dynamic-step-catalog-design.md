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
- Python script auto-discovery as catalog source (#441)

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

    public boolean validate(Object value) {
        return switch (this) {
            case STRING  -> value instanceof String;
            case INTEGER -> value instanceof Integer || value instanceof Long;
            case NUMBER  -> value instanceof Number;
            case BOOLEAN -> value instanceof Boolean;
            case ARRAY   -> value instanceof java.util.List;
            case OBJECT  -> value instanceof java.util.Map;
        };
    }

    public Object parseScalar(String value) {
        return switch (this) {
            case STRING  -> value;
            case INTEGER -> Integer.parseInt(value);
            case NUMBER  -> Double.parseDouble(value);
            case BOOLEAN -> io.casehub.yaml.core.condition.Truthiness.isTruthy(value);
            case ARRAY, OBJECT -> throw new IllegalArgumentException(
                    "Cannot parse '" + this + "' from string — "
                    + "defaults are only supported for scalar types");
        };
    }
}
```

`validate(Object)` performs runtime type checking of values against the declared type. `parseScalar(String)` converts string defaults to typed values — available only for scalar types. OBJECT and ARRAY parameters cannot have string defaults because yaml-core is zero-dep (no JSON parser). Defaults for OBJECT/ARRAY are not supported; if a complex default is needed, it must be provided by the caller at invocation time.

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
        if (defaultValue != null && !type.isScalar()) {
            throw new IllegalArgumentException(
                    "Default values are only supported for scalar types, not " + type);
        }
    }
}
```

`defaultValue` is `String` — consistent with `YamlModuleParameter.defaultValue`. Values arrive as YAML text; parsing to the declared type happens at validation time via `StepParameterType.parseScalar()`. This avoids YAML parser inference issues where `42` might arrive as `Integer` or `Long` depending on magnitude. Default values are restricted to scalar types (STRING, INTEGER, NUMBER, BOOLEAN) because yaml-core has no JSON parser for complex type defaults.

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
                 String model,
                 String timeout,
                 boolean structuredOutput) implements InvokeBinding {
        public Agent {
            if (descriptor == null)
                throw new IllegalArgumentException(
                        "Agent binding requires descriptor");
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

**Agent binding — eidos descriptor resolution:** The `descriptor` field is an eidos `agentId` or `name`, resolved at handler creation time via the platform's `AgentDescriptorRegistrar` SPI (from `casehub-eidos-api`). The eidos `AgentDescriptor` provides:

- `briefing()` → systemPrompt for `AgentSessionConfig`
- `modelFamily()` / `modelVersion()` → model selection (routed through `RoutingAgentProvider`)
- `jurisdiction()`, `dataHandlingPolicy()` → compliance metadata (logged, not enforced at this layer)
- `goals()`, `constraints()` → included in systemPrompt construction

The `model` field on `InvokeBinding.Agent` is an override — it takes precedence over the descriptor's `modelFamily` if both are specified. `timeout` is a duration string (e.g. `30s`, `5m`) parsed at handler creation time.

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
- Parameter types match declared types via `StepParameterType.validate(Object)` — STRING validated as `String`, INTEGER as `Integer`/`Long`, NUMBER as `Number`, BOOLEAN as `Boolean`, ARRAY as `List`, OBJECT as `Map`
- Enum values are within allowedValues
- Format constraints validated for STRING parameters with a `format` field:
  - `date` → `java.time.LocalDate.parse(value)` (ISO-8601 date)
  - `date-time` → `java.time.OffsetDateTime.parse(value)` (ISO-8601 date-time)
  - `uri` → `java.net.URI.create(value)` (valid URI syntax)
  - Unknown format strings are ignored (documentation-only — used for JSON Schema generation in #437)
  - All validation uses JDK classes only (zero-dep compatible)
- Output fields match declared output schema

**Load-time output reference validation** (`${result.action-name.field}` expressions) is a playbook loader concern, not a StepValidator concern. The step catalog provides the output schema via `StepDefinition.outputs()`; the playbook loader (in the consumer — Pages, desiredstate) cross-references expression references against this schema. The expression parser that extracts `${result.*}` references uses yaml-core's existing `VariableResolver` infrastructure — `result` is registered as a variable prefix, and the playbook loader validates that each referenced field exists in the resolved action's output declarations.

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

Dependencies: yaml-core, yaml-plugin-api, yaml-jackson, jackson-databind, quarkus-arc, platform-api (for AgentProvider, MCP), eidos-api (for AgentDescriptor resolution).

#### InvokeHandler SPI

```java
public interface InvokeHandler {

    boolean supports(InvokeBinding binding);

    StepAction create(StepDefinition definition, InvokeBinding binding);
}
```

Each invoke handler converts an `InvokeBinding` (data) into a `StepAction` (executable). The handler factory pattern lets the composite catalog assemble actions from definitions without knowing which binding type is being used.

#### CatalogSource SPI

```java
public interface CatalogSource {

    void populate(Map<String, CatalogEntry> entries);

    int priority();
}
```

Each catalog source populates entries in priority order. First-write-wins: lower priority numbers register first and are not overwritten by higher-priority (later) sources.

#### Six invoke handlers

**McpInvokeHandler** — Calls an MCP tool by name via the platform's existing tool infrastructure. Injects the MCP tool manager. Maps step inputs to MCP tool parameters and MCP tool result to step outputs.

**RestInvokeHandler** — HTTP request via `java.net.http.HttpClient`. Variable interpolation in URL, headers, and body from step inputs (`${paramName}`). Response parsed as JSON. Timeout from step definition or default.

**GraphqlInvokeHandler** — Executes a GraphQL query against the application's endpoint. Variable interpolation from step inputs. Uses platform's existing SmallRye GraphQL client. Response mapped to step outputs.

**PythonInvokeHandler** — Subprocess execution of a Python script. Step inputs serialized as JSON to stdin. Step outputs read as JSON from stdout. Timeout enforcement. Error reporting from stderr. No GraalPy — subprocess isolation is portable and secure.

**AgentInvokeHandler** — Dispatches to an LLM agent via `AgentProvider` SPI (already in platform).

Resolution: The `descriptor` field on `InvokeBinding.Agent` is resolved via `AgentDescriptorRegistrar` (eidos SPI). The registrar is injected as `Instance<AgentDescriptorRegistrar>` — all registered descriptors are searched by agentId first, then by name.

**Execution model:**
- Constructs `AgentSessionConfig` from the eidos `AgentDescriptor`: `briefing()` → systemPrompt, step inputs serialized as JSON → userPrompt, `modelFamily()` → model (overridden by InvokeBinding.Agent.model if set), timeout from binding or default.
- Calls `AgentProvider.invoke(config)` which returns `Multi<AgentEvent>` (reactive stream).
- Blocks via `.collect().asList().await().atMost(timeout)` — safe on virtual threads (the platform's execution model). Must NOT run on the Vert.x event loop.
- Collects `AgentEvent.TextDelta` events into final text.
- `AgentTimeoutException` and `AgentProcessException` map to `StepResult.Failure` with descriptive messages.
- When `structuredOutput: true`, parses the collected text as JSON and validates against the step's declared output schema. Parse failure → `StepResult.Failure`.

**ProcessInvokeHandler** — Runs a CLI command via `ProcessBuilder`. Args with variable interpolation. Output parsing: json (Jackson), csv (CsvParser from yaml-core), lines (split), raw (string). Timeout via `Process.waitFor(timeout)`. Environment variables and working directory. Error construction from stderr or exit code.

#### Execution metadata

Handler-specific telemetry (agent token counts/cost, process exit codes, HTTP status codes) flows from handlers to consumers via `StepResult.Success.executionMetadata()`.

**StepResult extension (yaml-plugin-api):** `StepResult.Success` gains an `executionMetadata` field:

```java
public sealed interface StepResult permits StepResult.Success, StepResult.Failure {

    boolean isSuccess();
    Map<String, Object> output();
    default Map<String, Object> executionMetadata() { return Map.of(); }

    record Success(Map<String, Object> output,
                   Map<String, Object> executionMetadata) implements StepResult {
        public Success {
            output = Map.copyOf(output);
            executionMetadata = executionMetadata != null ? Map.copyOf(executionMetadata) : Map.of();
        }
        @Override public boolean isSuccess() { return true; }
    }

    record Failure(String message) implements StepResult {
        @Override public boolean isSuccess() { return false; }
        @Override public Map<String, Object> output() { return Map.of(); }
    }

    static StepResult of(Map<String, Object> output) { return new Success(output, Map.of()); }
    static StepResult of(Map<String, Object> output, Map<String, Object> executionMetadata) {
        return new Success(output, executionMetadata);
    }
    static StepResult failed(String message) { return new Failure(message); }
}
```

`executionMetadata` is distinct from `output` — output is the step's declared result schema (validated against StepDefinition.outputs()); metadata is execution telemetry (cost, timing, model used). The existing `StepResult.of(output)` factory defaults metadata to `Map.of()` — backwards-compatible for existing `@StepPlugin` implementations.

Handlers populate metadata during `execute()`: AgentInvokeHandler includes `InvocationComplete` fields (tokenCount, cost, model); ProcessInvokeHandler includes exit code and command duration; RestInvokeHandler includes HTTP status code and response time. `ValidatingStepAction` reads `result.executionMetadata()` and includes it in the `StepExecutionEvent`.

**StepExecutionEvent (yaml-step-runtime):**

```java
public record StepExecutionEvent(
        String actionName,
        long durationMs,
        boolean success,
        Map<String, Object> metadata) {}
```

`ValidatingStepAction` fires `StepExecutionEvent` after each step execution. Consumers (audit loggers, cost trackers, observability) observe this event via CDI `@Observes`.

#### Trust model

Step definitions are versioned, developer-reviewed artifacts — not arbitrary user input. The trust boundary is deployment access: who can commit step definition files to the repository. This is consistent with how Ansible treats Python modules and how Terraform treats providers.

ProcessInvokeHandler and PythonInvokeHandler execute external code. Their security depends on the same controls that govern any server-side code: code review, CI gates, deployment permissions.

Further hardening (allow-lists, resource limits, sandboxing) is deferred to #440.

#### Validation-wrapping

Each `StepAction` returned by an invoke handler is wrapped with input/output validation and execution event emission:

```java
class ValidatingStepAction implements StepAction {
    private final StepDefinition definition;
    private final StepAction delegate;
    private final Event<StepExecutionEvent> executionEvent;

    @Override
    public StepResult execute(Map<String, Object> params, ServiceRegistry services) {
        List<String> inputErrors = StepValidator.validateStep(
                definition.name(), params, definition);
        if (!inputErrors.isEmpty()) {
            return StepResult.failed("Input validation: " + String.join("; ", inputErrors));
        }

        long start = System.nanoTime();
        StepResult result = delegate.execute(params, services);
        long durationMs = (System.nanoTime() - start) / 1_000_000;

        if (result.isSuccess()) {
            List<String> outputErrors = StepValidator.validateOutputs(
                    result.output(), definition);
            if (!outputErrors.isEmpty()) {
                return StepResult.failed("Output validation: " + String.join("; ", outputErrors));
            }
        }

        Map<String, Object> metadata = result.isSuccess()
                ? result.executionMetadata()
                : Map.of("error", ((StepResult.Failure) result).message());
        executionEvent.fireAsync(new StepExecutionEvent(
                definition.name(), durationMs, result.isSuccess(), metadata));

        return result;
    }
}
```

#### CompositeStepCatalog

```java
@ApplicationScoped
public class CompositeStepCatalog implements StepCatalog {

    private final Map<String, CatalogEntry> entries = new ConcurrentHashMap<>();
    private volatile boolean initialized = false;

    @Override
    public Optional<CatalogEntry> resolve(String actionName) {
        if (!initialized) {
            throw new IllegalStateException("Step catalog not yet initialized");
        }
        return Optional.ofNullable(entries.get(actionName));
    }

    @Override
    public Set<String> availableActions() {
        return Set.copyOf(entries.keySet());
    }
}
```

**Initialization protocol:** `CompositeStepCatalog` discovers all `CatalogSource` beans via CDI `Instance<CatalogSource>`, sorts by `priority()`, and invokes `populate()` on each in order. This happens in a `@PostConstruct` method on the `@Startup`-annotated catalog bean. After all sources have populated, `initialized` is set to `true`.

The source count is dynamic — determined by which `CatalogSource` beans are on the classpath. No fixed latch count. If McpToolSource is absent (MCP not on classpath), it is simply not discovered and does not participate.

Three built-in catalog sources:

**YamlStepDefinitionSource** `priority 100` — Reads step definition YAML files from configurable paths (`casehub.steps.definition-files`). Parses via `StepDefinitionParser`. For each action, resolves the `InvokeBinding` to a `StepAction` via the `InvokeHandler` registry. Wraps with validation.

**AptPluginSource** `priority 200` — Scans `META-INF/yaml-plugins/*.json` manifests on the classpath (produced by existing `@StepPlugin` APT processor). Loads `StepAction` implementation classes. Reads schema from `META-INF/yaml-plugins/<name>.schema.json` and constructs a synthetic `StepDefinition` from the schema.

**McpToolSource** `priority 300` — Auto-discovers MCP tools registered in the platform's MCP tool registry. Each tool becomes a catalog entry with `InvokeBinding.Mcp(toolName)`. Input schema derived from MCP tool parameter schema. Optional — activated when MCP infrastructure is on classpath.

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
| `yaml-step-runtime/` | **New module** — CatalogEntry, StepCatalog SPI, CatalogSource SPI, CompositeStepCatalog, InvokeHandler SPI, 6 invoke handler implementations, 3 catalog sources (YAML, APT, MCP), ValidatingStepAction wrapper, ImportScopedStepCatalog, StepExecutionEvent |

### What does NOT change

- `yaml-plugin-api/` — remains zero-dependency. `StepResult.Success` gains an `executionMetadata` field; existing `StepResult.of(output)` factory is backwards-compatible (defaults metadata to `Map.of()`).
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
| Platform simulation | InvokeHandler SPI is the simulation extension point — a `SimulatedInvokeHandler` can intercept any invoke binding and return recorded/synthetic responses without executing the real binding. Full simulation integration is a follow-on concern |
| MCP tool registry | MCP tools are auto-discoverable catalog entries via McpToolSource |
| Eidos agent descriptors | Agent invoke bindings reference eidos `AgentDescriptor` by agentId/name. Resolution via `AgentDescriptorRegistrar` SPI |

## Non-goals

- **Inline scripting** — no code embedded in YAML. Scripts are external files.
- **Turing-complete YAML** — step definitions declare schemas and invoke bindings, not logic.
- **Replacing @StepPlugin** — Java plugins remain the compile-time-safe path.
- **IDE schema generation** — deferred follow-on (#437).
- **LSP-based import resolution** — deferred follow-on (#438).
- **StepParameterType / ParameterType convergence** — deferred evaluation (#439).
- **Security hardening for invoke handlers** — deferred follow-on (#440).
- **Python script auto-discovery** — deferred follow-on (#441).

## References

- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StepAction.java` — execution contract
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StepResult.java` — result sealed interface
- `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/RegistryEmitter.java` — APT manifest format
- `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/SchemaEmitter.java` — APT schema format
- `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterType.java` — module type enum (not used by step definitions)
- `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleParameter.java` — parameter model (String defaultValue pattern)
- `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlModuleFileMixin.java` — @JsonAnySetter pattern for dynamic YAML sections
- `io.casehub.eidos.api.AgentDescriptor` — eidos agent descriptor record (descriptor resolution target)
- `io.casehub.eidos.api.spi.AgentDescriptorRegistrar` — eidos descriptor registry SPI
- GitHub #433, #429, #432, #437, #438, #439, #440, #441, casehubio/casehub-pages#463
