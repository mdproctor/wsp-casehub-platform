# Playbook variable declarations — vars:, params:, typed variable context

**Branch:** issue-703-playbook-variable-declarations
**Covers:** #703
**Parent epic:** #702 (YAML playbook polish)
**Repo:** casehubio/platform

## Problem

Playbooks have no variable declaration mechanism. Variables come into existence only through `capture:` (step output) and `forEach:` (iteration). There is no way to declare local state, typed parameters, or default values. The module system (`YamlModuleParameter`) solves this for modules but playbooks don't use it.

This means:
- No pre-flight validation of variable types
- No declared parameters for `run-playbook` callers to know what to pass
- No local state initialisation without a step producing it
- No type checking on `${var.name}` access

## Design

### Four sources of variables in the playbook context

| Source | Prefix | Scope | When populated |
|--------|--------|-------|----------------|
| `params:` | `${params.name}` | External — caller provides | Parse time |
| `vars:` | `${var.name}` | Internal — local state | Parse time (defaults) |
| `@Inject` | TBD (#700) | External — container provides | Startup |
| `capture:` | `${capture.name}` | Internal — step output | Execution |

All four populate the same `VariableResolver`. Steps reference them via prefix-based syntax — `${var.name}`, `${params.name}`. The difference is provenance.

### 1. TypedName extension — scalars + domain types

`TypedName` is extended from `record TypedName(String name, ValueType type)` to:

```java
public record TypedName(String name, String typeName, ValueType scalarType) {
    public TypedName {
        if (name == null || name.isBlank())
            throw new IllegalArgumentException("Variable name must not be blank");
        if (typeName == null || typeName.isBlank())
            throw new IllegalArgumentException("Type name must not be blank");
    }

    public boolean isScalar() { return scalarType != null; }

    public static TypedName parse(String raw) {
        int colon = raw.indexOf(':');
        if (colon < 0) return new TypedName(raw.trim(), "string", ValueType.STRING);
        String name = raw.substring(0, colon).trim();
        String typePart = raw.substring(colon + 1).trim();
        if (typePart.isEmpty())
            throw new IllegalArgumentException(
                "Missing type after ':' in '" + raw + "'.");
        ValueType scalar = ValueType.fromString(typePart);
        return new TypedName(name, typePart, scalar);
    }
}
```

When `typePart` matches a `ValueType` (STRING, INTEGER, BOOLEAN, NUMBER), `scalarType` is populated. For domain types like `AgentSessionConfig`, `scalarType` is null and `typeName` carries the opaque label.

**Backward compatibility:** `CsvParser` calls `TypedName.parse()` and then uses `.scalarType()` (previously `.type()`). It already enforces scalars-only at its call site by checking for a colon in the header. The existing `CsvParser` code will need to use `.scalarType()` instead of `.type()` — a mechanical rename.

### 2. TypedVariables extension for domain types

`TypedVariables.parse()` is extended to handle domain types:

```java
public static TypedMap parse(Map<String, Object> rawVariables) {
    var schema = new LinkedHashMap<String, ValueType>();
    var domainTypes = new LinkedHashMap<String, String>();
    var values = new LinkedHashMap<String, Object>();
    for (var entry : rawVariables.entrySet()) {
        TypedName tn = TypedName.parse(entry.getKey());
        Object raw = entry.getValue();
        if (tn.isScalar()) {
            schema.put(tn.name(), tn.scalarType());
            if (tn.scalarType().validate(raw)) {
                values.put(tn.name(), raw);
            } else {
                values.put(tn.name(), tn.scalarType().parse(String.valueOf(raw)));
            }
        } else {
            domainTypes.put(tn.name(), tn.typeName());
            values.put(tn.name(), raw); // stored as-is (Map<String,Object> or scalar)
        }
    }
    return new TypedMap(Map.copyOf(schema), Map.copyOf(values), Map.copyOf(domainTypes));
}
```

`TypedMap` gains an optional `domainTypes` field:

```java
public record TypedMap(Map<String, ValueType> schema,
                       Map<String, Object> values,
                       Map<String, String> domainTypes) implements TypedSchema {
    public TypedMap(Map<String, ValueType> schema, Map<String, Object> values) {
        this(schema, values, Map.of());
    }
    // existing TypedSchema methods unchanged
}
```

### 3. Playbook YAML syntax

#### Short form — inline defaults

```yaml
vars:
  retryCount:integer: 0
  threshold:number: 0.85
  result:AgentInvocationResult:
  config:AgentSessionConfig:
    model: "claude-3"
    timeout: 30s
```

Rule: colon in the key = explicit type. No colon = inferred from the value:

```yaml
vars:
  count: 42           # inferred integer
  name: "hello"       # inferred string
  active: true        # inferred boolean
```

If inference fails (null value, no type annotation), parse error.

#### params: — playbook public interface

```yaml
params:
  portfolio:string:              # required, no default
  tier:string: "standard"        # optional with default
```

Short form: `name:type:` with optional default value. A param with no default is required. A param with a default is optional.

#### Long form — constraints

For the long form, `name:type:` becomes the key with a map value reusing `YamlModuleParameter` schema:

```yaml
params:
  maxRetries:integer:
    default: 3
    minimum: 1
    maximum: 10
  tier:string:
    default: "standard"
    allowedValues: ["basic", "standard", "premium"]
```

### 4. PlaybookVariableContext — parsed result

New record in `playbook-compiler` that wraps `PlaybookVariableParser.ParsedVariables`:

```java
public record PlaybookVariableContext(
        Map<String, YamlModuleParameter> params,
        TypedMap vars) {

    public static final PlaybookVariableContext EMPTY =
        new PlaybookVariableContext(Map.of(), new TypedMap(Map.of(), Map.of()));

    public static PlaybookVariableContext from(PlaybookVariableParser.ParsedVariables parsed) {
        return new PlaybookVariableContext(parsed.params(), parsed.vars());
    }

    public VariableResolver buildResolver(Map<String, String> callerParams,
                                          Set<String> deferredPrefixes) {
        // Validate caller params against declared params
        if (!params.isEmpty()) {
            ParameterValidator.validateOrThrow(params, callerParams);
        }

        // Build resolver with params and var prefixes
        VariableResolver resolver = VariableResolver.forParams(params, callerParams, deferredPrefixes);

        // Add vars as an object scope for typed access (maps, domain objects)
        if (!vars.values().isEmpty()) {
            resolver = resolver.withObjectScope("var",
                name -> vars.values().get(name));
        }

        return resolver;
    }
}
```

### 5. PlaybookVariableParser — parsing logic

New class in yaml-core's playbook subpackage. Returns raw parsed data — not `PlaybookVariableContext` (which lives in playbook-compiler). This keeps the parser reusable without a compiler dependency.

```java
public final class PlaybookVariableParser {

    public record ParsedVariables(
            Map<String, YamlModuleParameter> params,
            TypedMap vars) {
        public static final ParsedVariables EMPTY =
            new ParsedVariables(Map.of(), new TypedMap(Map.of(), Map.of()));
    }

    public static ParsedVariables parse(Map<String, Object> content) {
        Map<String, YamlModuleParameter> params = parseParams(content.get("params"));
        TypedMap vars = parseVars(content.get("vars"));
        return new ParsedVariables(params, vars);
    }

    private static TypedMap parseVars(Object raw) {
        if (raw == null) return new TypedMap(Map.of(), Map.of());
        if (!(raw instanceof Map<?, ?>)) throw new IllegalArgumentException("vars: must be a map");
        return TypedVariables.parse(asStringKeyedMap(raw));
    }

    private static Map<String, YamlModuleParameter> parseParams(Object raw) {
        if (raw == null) return Map.of();
        if (!(raw instanceof Map<?, ?>)) throw new IllegalArgumentException("params: must be a map");
        var result = new LinkedHashMap<String, YamlModuleParameter>();
        for (var entry : asStringKeyedMap(raw).entrySet()) {
            TypedName tn = TypedName.parse(entry.getKey());
            ParameterType paramType = tn.isScalar()
                ? tn.scalarType().toParameterType()
                : ParameterType.OBJECT;
            Object value = entry.getValue();

            if (value == null) {
                // name:type: with no value → required, no default
                result.put(tn.name(), YamlModuleParameter.builder()
                    .type(paramType).required(true).build());
            } else if (value instanceof Map<?, ?> constraintMap) {
                // Long form: name:type: { default: ..., minimum: ..., ... }
                var map = asStringKeyedMap(constraintMap);
                var builder = YamlModuleParameter.builder().type(paramType);
                if (map.containsKey("default"))
                    builder.defaultValue(String.valueOf(map.get("default")));
                else
                    builder.required(true);
                if (map.get("minimum") instanceof Number n) builder.minimum(n);
                if (map.get("maximum") instanceof Number n) builder.maximum(n);
                if (map.get("minLength") instanceof Number n) builder.minLength(n.intValue());
                if (map.get("maxLength") instanceof Number n) builder.maxLength(n.intValue());
                if (map.get("pattern") instanceof String s) builder.pattern(s);
                if (map.get("allowedValues") instanceof List<?> list)
                    builder.allowedValues(list.stream().map(String::valueOf).toList());
                if (map.get("constraintDescription") instanceof String s)
                    builder.constraintDescription(s);
                result.put(tn.name(), builder.build());
            } else {
                // Short form: name:type: value → optional with default
                result.put(tn.name(), YamlModuleParameter.builder()
                    .type(paramType).defaultValue(String.valueOf(value)).build());
            }
        }
        return Map.copyOf(result);
    }
}
```

### 6. PlaybookCompiler integration

`PlaybookCompiler.compile()` extracts `vars:` and `params:` before compiling steps:

```java
public CompilationOutcome compile(String name, Map<String, Object> content) {
    // ... existing code ...

    // NEW: parse variable declarations
    PlaybookVariableContext variableContext =
        PlaybookVariableContext.from(PlaybookVariableParser.parse(content));

    // ... existing steps compilation ...

    return new CompilationOutcome.Success(
        new CompilationResult(workflow, coordination.build(), sourceMap.build(),
                              poolDeclarations, variableContext));
}
```

`CompilationResult` gains a `variableContext` field.

### 7. RunPlaybookPlugin integration

`RunPlaybookPlugin` is updated to:

1. Parse the sub-playbook's `params:` section
2. Extract caller-provided `vars:` from the step parameters (via Walker's sibling absorption)
3. Validate caller vars against declared params using `ParameterValidator`
4. Build a `VariableResolver` from the variable context
5. Run the sub-playbook's steps with the new resolver

```yaml
# Caller
- run-playbook: assessments/risk.yaml
  vars:
    portfolio: "growth-fund"
  capture: results
```

```yaml
# Sub-playbook: assessments/risk.yaml
params:
  portfolio:string:    # required

vars:
  retryCount:integer: 0

steps:
  - agent-invoke:
      prompt: "Assess ${params.portfolio}"
```

The `run-playbook` plugin uses `absorbSiblings` (already supported by Walker) to absorb `vars:` as a sibling key. It then passes the caller's vars as `callerParams` to `PlaybookVariableContext.buildResolver()`.

### 8. Test infrastructure integration

`YamlTestExecutor` is updated to parse `vars:` and `params:` from test playbooks, building the initial `VariableResolver` with declared variables before running steps. Test files can provide param values via a new `params:` section in the test case:

```yaml
name: risk-assessment-test
params:
  portfolio: "test-fund"
steps:
  - run-playbook: assessments/risk.yaml
    vars:
      portfolio: ${params.portfolio}
    capture: result
  - assert-equals:
      actual: ${capture.result.succeeded}
      expected: true
```

### 9. Type inference for untyped vars

When `vars:` entries have no type annotation (no colon in the key), the type is inferred from the YAML-parsed value:

| Java type | Inferred ValueType |
|-----------|--------------------|
| `Integer`, `Long` | INTEGER |
| `Double`, `Float` | NUMBER |
| `Boolean` | BOOLEAN |
| `String` | STRING |
| `Map` | No scalar type (typeName = "object", scalarType = null) |
| `List` | No scalar type (typeName = "list", scalarType = null) |

If the value is `null` and no type annotation is present, it's a parse error — every variable must either have a type annotation or a value from which the type can be inferred.

## Module placement

| Change | Module |
|--------|--------|
| TypedName extension | yaml-core |
| TypedMap extension (domainTypes) | yaml-core |
| TypedVariables extension | yaml-core |
| PlaybookVariableParser | yaml-core (playbook subpackage) |
| PlaybookVariableContext | playbook-compiler |
| CompilationResult extension | playbook-compiler |
| PlaybookCompiler changes | playbook-compiler |
| RunPlaybookPlugin changes | yaml-step-runtime |
| YamlTestExecutor changes | yaml-test-core |

`PlaybookVariableParser` goes in yaml-core because it only depends on `TypedVariables`, `TypedName`, and `YamlModuleParameter` — all yaml-core types. It returns `ParsedVariables` (a record of params map + TypedMap), keeping the parser reusable outside the compiler.

`PlaybookVariableContext` goes in playbook-compiler because it wraps `ParsedVariables` and adds `buildResolver()` — a compilation concern that produces a `VariableResolver` and validates caller params. It bundles into `CompilationResult`.

## Scope boundary

**In scope:**
- `vars:` and `params:` parsing with `name:type:` compound key syntax
- Scalar types (STRING, INTEGER, BOOLEAN, NUMBER) with value parsing/validation
- Domain types as opaque labels (values stored as-is)
- Constraint long form reusing `YamlModuleParameter`
- Type inference for untyped vars
- `PlaybookCompiler` integration
- `RunPlaybookPlugin` param validation
- `YamlTestExecutor` integration

**Out of scope (deferred):**
- Domain type deserialization (#699)
- `@Inject` container injection (#700)
- Module imports and param passing (#701)
- JSON Schema generation for playbooks (#705)
- Bare variable references (`${name}` without prefix)

## References

- TypedName.java — existing `name:type` parsing infrastructure from #429
- TypedVariables.java — existing typed variable parsing (currently orphaned — no callers outside tests)
- TypedMap.java — typed variable storage with schema
- ValueType.java — scalar type enum with parse/validate
- YamlModuleParameter.java — constraint model for typed parameters
- ParameterValidator.java — constraint validation engine
- VariableResolver.java — prefix-based variable resolution, `forParams()` factory
- PlaybookCompiler.java — compilation entry point, section extraction pattern
- RunPlaybookPlugin.java — sub-playbook execution, needs vars: passing
- YamlTestExecutor.java — test runner, needs resolver initialisation from vars/params
- Issue #429 — YAML surface type system (compound key syntax foundation)
- Issue #699 — Type-safe expression resolution (domain type deserialization, future)
- Issue #700 — `@Inject` annotations (container injection, future)
