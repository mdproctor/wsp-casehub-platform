# Trust model for playbook authoring — design spec

**Issue:** casehubio/platform#830
**ADR:** 0013-trust-model-for-playbook-authoring.md
**Direction:** LD-9, TN-2 in playbook-direction.md
**Prerequisite for:** WS-6b (validator MCP tool)

## Problem

Playbook steps `process`, `rest-call`, MVEL expressions, and variable sources `env()`/`systemProperty()` make a playbook equivalent to arbitrary code. The validator MCP tool (WS-6b) will expose the step catalogue to LLMs. Without filtering, LLM-authored playbooks can run shell commands or exfiltrate secrets.

## Design

### Two authoring contexts

| Context | Who | Available |
|---------|-----|-----------|
| `developer` | Human in IDE/CLI | Everything — unfiltered registry |
| `assisted` | LLM via validator MCP tool | Everything except `process-execution`, `raw-http`, `expression-mvel`, `env-access` |

Assignment is by calling context, not playbook header. The validator tool passes `assisted`; CLI defaults to `developer`.

### Implementation: extend the capability taxonomy

Four new constants in `PlaybookCapabilities`:

```java
public static final String PROCESS_EXECUTION = "process-execution";
public static final String RAW_HTTP = "raw-http";
public static final String EXPRESSION_MVEL = "expression-mvel";
public static final String ENV_ACCESS = "env-access";
```

Reclassify steps:
- `process` plugin: `capability` changes from `"steps"` to `"process-execution"`
- `rest-call` plugin: `capability` changes from `"steps"` to `"raw-http"`

Add all four risk capabilities to `server` and `client` built-in schemas (preserves current developer behaviour).

New built-in schema `assisted` in `MapPlaybookSchemaRegistry`:

```java
var assistedCaps = new HashSet<>(SHARED_CAPABILITIES);
assistedCaps.addAll(Set.of(ORCHESTRATION, CORRELATION, MCP_INVOKE, GRAPHQL_INVOKE, CODEGEN));
// Excludes: PROCESS_EXECUTION, RAW_HTTP, EXPRESSION_MVEL, ENV_ACCESS
register(PlaybookSchemaDescriptor.builtIn(PlaybookSchemas.ASSISTED, assistedCaps));
```

### WS-6b integration point

The validator MCP tool creates its filtered registry with:

```java
SchemaFilteredRegistry.forSchema(registry, schemas, "assisted")
```

This is the entire integration surface. `SchemaFilteredRegistry.availableActions()` returns only steps whose capabilities match the `assisted` schema — the LLM sees a safe catalogue.

### Variable sources

`VariableSource.env()` and `systemProperty()` are not registered in production. The trust model formalises this: registration of these sources is gated by the `ENV_ACCESS` capability in the active schema. When running under the `assisted` context, the resolver chain must not include these sources.

### Expression engines

MVEL is gated by `EXPRESSION_MVEL`. JQ (pure JSON transform, no side effects) and JEXL (sandboxed) remain available in both contexts.

The expression engine registry checks the active schema's capabilities before compiling an MVEL expression. Under `assisted`, MVEL compilation returns an error with a message indicating the expression type is not available in this authoring context.

### Configuration

```yaml
casehub:
  playbook:
    trust:
      default-context: developer  # developer | assisted
```

Default is `developer` — no breaking change. The MCP tool overrides this.

### What this issue delivers

1. ADR 0013 (this design as a decision record)
2. `PlaybookCapabilities` — four new constants
3. `PlaybookSchemas` — new `ASSISTED` constant
4. `MapPlaybookSchemaRegistry` — new `assisted` built-in schema; `server` and `client` schemas gain the four risk capabilities
5. Step reclassification — `process` and `rest-call` plugins change their `capability` field
6. Tests — `SchemaFilteredRegistryTest` extended to verify assisted filtering

### What WS-6b delivers (not this issue)

- Validator MCP tool uses `SchemaFilteredRegistry.forSchema(registry, schemas, "assisted")`
- Expression engine integration with schema capability checks
- Variable source registration gating

## References

- `SchemaFilteredRegistry.java` — existing filtering decorator
- `PlaybookCapabilities.java` — capability constants
- `MapPlaybookSchemaRegistry.java` — built-in schema registration
- `PlaybookSchemaDescriptor.java` — schema record with inheritance
- `VariableSource.java:18-24` — `env()` and `systemProperty()` factories
- `Definition.java:9` — `capability` field on step definitions
- `playbook-direction.md` — LD-9, TN-2
- P26 (playbook equivalent to code), P42 (env/systemProperty sources)
