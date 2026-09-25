# Dynamic Step Catalog — schema-validated YAML step definitions

**Covers:** #433
**Repo:** casehubio/platform
**Depends on:** #429 (ValueType, ParameterType — landed), #432 (ImportExpander — landed)

## Problem

yaml-core provides coordination primitives (state machines, barriers, semaphores, channels). The `@StepPlugin` system provides type-safe step actions with compile-time validation. But adding a new step action requires a Java record, APT compilation, and redeployment.

For FSI operations teams writing playbooks (risk response, trading desk coordination, compliance workflows), every new step action requires a developer. The coordination YAML is operationally editable; the step vocabulary is not.

## Scope

**In scope:** Step definition YAML model, step catalog SPI + composite registry, all 6 invoke binding handlers (MCP, REST, GraphQL, Python, Agent, Process), load-time playbook validation against catalog.

**Out of scope (follow-on):** IDE JSON Schema generation Maven plugin, LSP-based import resolution. Runtime validation at load time still catches errors; IDE autocomplete is a developer experience layer.

## Design

### Layer 1: Step definition model (yaml-core, zero-dep)

New types in `io.casehub.yaml.core.step`:

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

```java
public record StepParameter(
        ParameterType type,
        boolean required,
        Object defaultValue,
        List<String> allowedValues,
        String format,
        String description) {

    public StepParameter {
        if (type == null) type = ParameterType.STRING;
        if (allowedValues == null) allowedValues = List.of();
    }
}
```

`StepParameter` reuses `ParameterType` from yaml-core's module system (STRING, INTEGER, NUMBER, BOOLEAN, LIST) but is a separate record from `YamlModuleParameter`. The types serve different purposes — module parameters carry constraints (minLength, maxLength, pattern, minimum, maximum) that are module-expansion concerns. Step parameters carry format hints and description for schema documentation. They may converge later but start separate.

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
                 boolean structuredOutput) implements InvokeBinding {
        public Agent {
            if (descriptor == null)
                throw new IllegalArgumentException("Agent binding requires descriptor");
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
- Parameter types match declared types (via ParameterType)
- Enum values are within allowedValues
- Output fields match declared output schema

### Layer 2: Step catalog SPI (yaml-plugin-api, zero-dep)

yaml-plugin-api gains a compile dependency on yaml-core. Both are zero-dep pure Java — this is a clean dependency. **Boundary rule update:** CLAUDE.md states "yaml-plugin-api must remain zero-dependency." This change relaxes that rule to "zero-external-dependency" — yaml-core is also zero-dep, J2CL-safe pure Java. The spirit of the rule (plugin authors don't get Quarkus/JPA on their classpath) is preserved. CLAUDE.md must be updated when this lands.

New types in `io.casehub.yaml.plugin.api`:

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

**AgentInvokeHandler** — Dispatches to an LLM agent via `AgentProvider` SPI (already in platform). Resolves agent by descriptor name. When `structuredOutput: true`, validates agent response against output schema. Collects streaming `AgentEvent.TextDelta` into final text.

**ProcessInvokeHandler** — Runs a CLI command via `ProcessBuilder`. Args with variable interpolation. Output parsing: json (Jackson), csv (CsvParser from yaml-core), lines (split), raw (string). Timeout via `Process.waitFor(timeout)`. Environment variables and working directory. Error construction from stderr or exit code.

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

    // Sources registered in priority order:
    // 1. YAML step definition files (highest — explicit declarations)
    // 2. @StepPlugin APT-generated actions (compile-time plugins)
    // 3. MCP tool auto-discovery (runtime discovery)

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

### Playbook integration

Playbooks declare step definition imports:

```yaml
imports:
  - module: regional-pipeline
    as: region
  - steps: trading-steps.yaml    # step definition import
```

A new `steps` field on `YamlImport` (parallel to `module`). `steps` and `module` are mutually exclusive on a single import entry — an import is either a module import or a step definition import. Step imports only use the `steps` field; `as`, `parameters`, `forEach`, and `loop` are ignored (they're module-expansion concerns). `when` is valid on step imports (conditional step loading).

When the playbook loader encounters `steps:`, it loads the step definition file and registers its actions in the catalog for this playbook's scope. Import-scoped step definitions shadow catalog-level definitions. ImportExpander and ModuleExpander skip entries where `steps != null`.

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
| `yaml-core/` | New `io.casehub.yaml.core.step` package: StepDefinitionFile, StepDefinition, StepParameter, InvokeBinding, StepDefinitionParser, StepValidator |
| `yaml-plugin-api/` | New CatalogEntry record, StepCatalog interface. Gains compile dep on yaml-core |
| `yaml-jackson/` | StepDefinitionFileMixin, InvokeBindingDeserializer |
| `yaml-step-runtime/` | **New module** — CompositeStepCatalog, InvokeHandler SPI, 6 invoke handler implementations, 3 catalog sources (YAML, APT, MCP), ValidatingStepAction wrapper |

### What does NOT change

- `yaml-plugin-processor/` — APT processor is unchanged. It still generates to `META-INF/yaml-plugins/`. The new catalog simply reads what the processor already produces.
- `ModuleExpander` — unchanged; step definitions are not modules.
- `ForEachExpander` — unchanged; step definitions don't use forEach.
- `ImportExpander` — the `steps:` field on YamlImport is a model extension but ImportExpander only processes `forEach` and passes through other imports unchanged.

## Consumer integration

yaml-core provides the model and validation. yaml-plugin-api provides the catalog SPI. yaml-step-runtime provides the CDI implementation. A consumer (e.g., desiredstate's `YamlGraphRecorder`, or Pages' scenario YAML binding #463) adds yaml-step-runtime as a compile dependency and injects `StepCatalog`:

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
| yaml-core modules (`ModuleExpander`) | Separate concept. Step definitions reuse `ParameterType` but are not modules |
| Pages scenario YAML binding (#463) | Consumer — resolves `action:` references via StepCatalog |
| Platform simulation | Simulated step actions use the same schema. `@SimulationEligible` on invoke targets means step definitions work in simulation without modification |
| MCP tool registry | MCP tools are auto-discoverable catalog entries via McpToolSource |

## Non-goals

- **Inline scripting** — no code embedded in YAML. Scripts are external files.
- **Turing-complete YAML** — step definitions declare schemas and invoke bindings, not logic.
- **Replacing @StepPlugin** — Java plugins remain the compile-time-safe path.
- **IDE schema generation** — deferred follow-on (D1).

## References

- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StepAction.java` — execution contract
- `yaml-plugin-api/src/main/java/io/casehub/yaml/plugin/api/StepResult.java` — result sealed interface
- `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/RegistryEmitter.java` — APT manifest format
- `yaml-plugin-processor/src/main/java/io/casehub/yaml/plugin/processor/SchemaEmitter.java` — APT schema format
- `yaml-core/src/main/java/io/casehub/yaml/core/module/ParameterType.java` — shared type enum
- `yaml-core/src/main/java/io/casehub/yaml/core/module/YamlModuleParameter.java` — parameter model (reuse ParameterType, not the record)
- `yaml-jackson/src/main/java/io/casehub/yaml/jackson/YamlModuleFileMixin.java` — @JsonAnySetter pattern for dynamic YAML sections
- `platform/docs/platform/boundary-rules.md` — yaml-plugin-api zero-dep rule
- `platform/docs/platform/capability-ownership.md` — MCP tool registry ownership
- GitHub #433, #429, #432, casehubio/casehub-pages#463
