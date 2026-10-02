# Scenario Templates — Parameterized Include

**Issue:** casehubio/casehub-pages#327
**Branch:** epic-502-yaml-parity
**Date:** 2026-10-02

## Problem

Scenario YAML files repeat common setup patterns — creating customers,
seeding categories, establishing test state. There is no mechanism to
extract reusable scenario fragments. DRY requires parameterized,
composable templates.

## Design

### Scenario Format

A scenario declares includes at the top level (flat scenarios) or at
the section level (sectioned scenarios). Each include references a
template file and provides parameter values:

```yaml
scenario: helpdesk-demo
includes:
  - file: seeds/helpdesk-base.yaml
    params:
      customer: "Alice Chen"
      priority: "High"

steps:
  - name: inject-chat
    step: inject-chat
    delivery: graphql
    domain: connectors
    operation: injectChat
    params:
      sender: "Alice"
```

Sectioned scenarios support includes at both levels:

```yaml
scenario: helpdesk-tutorial
includes:
  - file: seeds/environment.yaml

sections:
  - title: "Onboarding"
    includes:
      - file: seeds/helpdesk-base.yaml
        params:
          customer: "Alice Chen"
    steps:
      - step: start-chat
        # ...
```

Top-level includes prepend their steps before the scenario's own steps.
Section-level includes prepend before that section's steps.
Multiple includes within the same block prepend in declaration order —
the first include's steps appear first.

### Template Format

Templates are scenario YAML files with a `params:` declaration. They
use `${params.name}` for parameter substitution and `when:` for
conditional step inclusion:

```yaml
# seeds/helpdesk-base.yaml
params:
  - name: customer
    type: string
    required: true
  - name: priority
    type: string
    required: false
    default: "Normal"

steps:
  - name: seed-customer
    step: seed-customer
    delivery: graphql
    domain: crm
    operation: createCustomer
    params:
      name: "${params.customer}"

  - name: seed-priority
    when: "${params.priority}"
    step: seed-priority
    delivery: graphql
    domain: engine
    operation: setDefaultPriority
    params:
      level: "${params.priority}"
```

### Parameter Declaration

Templates declare parameters using the same schema as the Java backend
(`ParamDescriptor`):

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| name | string | yes | Parameter name |
| type | string | no | `string` (default), `boolean`, `number`, `integer` |
| required | boolean | no | `false` by default |
| default | any | no | Default value when caller omits the param |
| enum | array | no | Allowed values |

### Expansion Pipeline

Expansion is a pre-processing phase that operates on raw parsed YAML
objects, before `Walker.resolve()`. The pipeline:

1. Parse YAML text → raw JS/Java objects
2. **IncludeExpander.expand()** — for each include:
   a. Load the template file via the caller-provided loader function
   b. Parse the template YAML
   c. Validate caller params against template's `params:` declaration
   d. Build a `VariableResolver` scoped to `params` prefix
   e. Resolve `${params.name}` in all step values via the resolver
   f. Evaluate `when:` conditions via `Truthiness` — filter out
      falsy steps
   g. Recursively expand any `includes:` in the template (nested
      includes), tracking visited files for cycle detection
   h. Prepend the surviving steps to the scenario's step array
3. Walker.resolve() on the flattened step list
4. Rest of the parsing pipeline unchanged

### Cycle Detection

The expander tracks include paths in a `Set<string>`. If a template
path appears in the ancestor set, the expander throws with a clear
error message showing the cycle:

```
Circular include detected: helpdesk-base.yaml → shared-setup.yaml → helpdesk-base.yaml
```

### IncludeExpander Interface

**TypeScript (yaml-core):**

```typescript
type TemplateLoader = (path: string) => Promise<string>;

interface IncludeDirective {
  file: string;
  params?: Record<string, unknown>;
}

interface ParamDescriptor {
  name: string;
  type?: 'string' | 'boolean' | 'number' | 'integer';
  required?: boolean;
  default?: unknown;
  enum?: unknown[];
}

class IncludeExpander {
  constructor(loader: TemplateLoader);

  async expand(
    parsed: Record<string, unknown>,
    ancestors?: Set<string>,
  ): Promise<Record<string, unknown>>;
}
```

The `expand` method:
- Reads `parsed['includes']` if present
- For each include directive, loads and expands the template
- Returns the modified parsed object with includes resolved and
  the `includes` key removed
- For sectioned scenarios, also processes `section.includes`

**Java (scenario module):**

```java
@FunctionalInterface
interface TemplateLoader {
    String load(String path);
}

class IncludeExpander {
    IncludeExpander(TemplateLoader loader);

    JsonNode expand(JsonNode parsed);
    JsonNode expand(JsonNode parsed, Set<String> ancestors);
}
```

### Parameter Validation

At expansion time, the expander validates:

1. **Required params:** All params with `required: true` and no
   `default` must be provided by the caller. Missing → error with
   template name and param name.
2. **Type checking:** Caller-provided values are checked against
   declared type. A string "true" for a boolean param is accepted
   (coerced). A string "abc" for an integer param → error.
3. **Enum validation:** If `enum` is declared, the value must be
   in the list.
4. **Unknown params:** Params provided by the caller that are not
   declared in the template → warning (not error), to support
   forward compatibility.

### Integration Points

**TypeScript — parseScenario (pages-aria):**

`parseScenario` gains an optional `TemplateLoader` parameter. When
provided, it runs `IncludeExpander.expand()` on the parsed YAML
before resolving steps:

```typescript
export async function parseScenario(
  yamlString: string,
  catalog: Catalog,
  loader?: TemplateLoader,
): Promise<Scenario>;
```

The function becomes async when a loader is provided. Callers that
don't use includes continue to call the synchronous version.

**TypeScript — scenario-controller (pages-aria):**

The controller provides a `TemplateLoader` that fetches templates
from the server via HTTP:

```typescript
const loader: TemplateLoader = async (path) => {
  const resp = await fetch(`${restBase}/scenario/templates/${path}`);
  if (!resp.ok) throw new Error(`Template not found: ${path}`);
  return resp.text();
};
```

**Java — HierarchicalParser:**

The parser gains an `IncludeExpander` parameter. The expander is
called on the root `JsonNode` before step parsing. The `TemplateLoader`
reads from the classpath or filesystem depending on deployment context.

### Error Handling

Errors during include expansion produce structured error messages:

| Error | Message |
|-------|---------|
| Template not found | `Include failed: template 'seeds/foo.yaml' not found` |
| Missing required param | `Include 'seeds/foo.yaml': missing required parameter 'customer'` |
| Type mismatch | `Include 'seeds/foo.yaml': parameter 'count' expects integer, got 'abc'` |
| Circular include | `Circular include detected: a.yaml → b.yaml → a.yaml` |
| Invalid enum value | `Include 'seeds/foo.yaml': parameter 'level' must be one of [Low, Medium, High], got 'None'` |
| No loader provided | `Scenario contains 'includes' but no template loader was provided` |

### Testing Strategy

**Unit tests (yaml-core TS):**
- Single include with params → steps prepended
- Multiple includes → steps prepended in order
- Nested includes → recursive expansion
- Cycle detection → error
- Missing required param → error
- Type validation → error/coercion
- `when:` filtering → conditional steps excluded
- Default values → applied when param omitted
- Section-level includes → section steps prepended
- Mixed top-level and section-level includes
- Template with no params → expanded as-is
- Unknown caller params → warning, not error

**Unit tests (Java scenario module):**
- Mirror all TS tests for parity

**Integration tests (pages-aria):**
- `parseScenario` with loader → includes expanded before Walker
- Scenario controller provides HTTP loader

## Non-Goals

- **Runtime call semantics** — the Java backend already has
  `action: call` with `script:` for runtime calls. This issue is
  parse-time expansion only.
- **Include-level orchestration** — templates contribute steps only,
  not orchestration blocks (machines, barriers, channels). Orchestration
  stays at the scenario level.
- **Dynamic include paths** — include file paths are static strings,
  not variable references. The path must be known at parse time.

## References

- variable-resolver.ts — VariableResolver `${prefix.name}` infrastructure
- import-expander.ts, module-expander.ts — existing yaml-core pre-expansion patterns
- parameterized-onboard.yaml — Java parameterized scenario example
- caller-script.yaml, callee-create-user.yaml — Java call semantics (not in scope)
- CallGraphValidator.java — cycle detection pattern
- ParamDescriptor.java — parameter declaration schema
- HierarchicalParser.java — Java scenario parser integration point
- parser.ts (pages-aria) — TS parseScenario integration point
- Truthiness (yaml-core) — boolean evaluation for `when:` conditions
