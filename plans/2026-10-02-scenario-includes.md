# Scenario Parameterized Includes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/casehub-pages#327 — Scenario templates parameterized include
**Issue group:** #502 (epic), #327

**Goal:** Add parse-time parameterized `@include` expansion to scenario
YAML in both TypeScript (yaml-core + pages-aria) and Java (scenario module).

**Architecture:** A new `IncludeExpander` operates on raw parsed YAML
objects before step resolution. It loads template files via a
caller-provided loader, validates params against the template's
declarations using existing `ParameterValidator`, resolves `${params.name}`
via `VariableResolver.forParams()`, evaluates `when:` conditions via
`Truthiness`/`isTruthy()`, and detects cycles via DFS ancestor tracking.
The expander is a pure YAML-object → YAML-object transform.

**Tech Stack:** TypeScript (vitest), Java (JUnit 5), yaml-core
(VariableResolver, ParameterValidator, isTruthy), Jackson

## Global Constraints

- yaml-core (TS) must remain zero-dependency except `zod`
- yaml-core (Java) must remain zero-dependency
- Use `${params.name}` syntax — NOT mustache `{{param}}`
- IncludeExpander must be async (TS) to support HTTP template loading
- Template files declare params in the same schema as Java `ParamDescriptor`
- Unknown caller params produce warnings (logged), not validation errors

---

## Batch 1: TS IncludeExpander in yaml-core

### Task 1: IncludeExpander — single include with param resolution

**Files:**
- Create: `packages/yaml-core/src/include-expander.ts`
- Create: `packages/yaml-core/src/include-expander.test.ts`
- Modify: `packages/yaml-core/src/index.ts` (add exports)

**Interfaces:**
- Consumes: `ParameterValidator.validate()` from `parameter-validator.ts`,
  `VariableResolver.forParams()` from `variable-resolver.ts`,
  `isTruthy()` from `truthiness.ts`,
  `YamlModuleParameter` type from `types.ts`
- Produces: `IncludeExpander.expand(parsed, loader, ancestors?)`,
  `TemplateLoader` type, `IncludeDirective` interface

- [ ] **Step 1: Write failing test — single include prepends steps**

```typescript
// include-expander.test.ts
import { describe, it, expect } from 'vitest';
import { IncludeExpander } from './include-expander.js';
import type { TemplateLoader } from './include-expander.js';

describe('IncludeExpander', () => {
  const seedTemplate = `
params:
  - name: customer
    type: string
    required: true
steps:
  - name: seed-customer
    step: seed-customer
    delivery: graphql
    domain: crm
    operation: createCustomer
    params:
      name: "\${params.customer}"
`;

  function mockLoader(files: Record<string, string>): TemplateLoader {
    return async (path: string) => {
      const content = files[path];
      if (!content) throw new Error(`Template not found: ${path}`);
      return content;
    };
  }

  it('expands a single include and prepends steps', async () => {
    const scenario = {
      scenario: 'demo',
      includes: [{ file: 'seeds/base.yaml', params: { customer: 'Alice' } }],
      steps: [{ name: 'main-step', step: 'main-action' }],
    };

    const loader = mockLoader({ 'seeds/base.yaml': seedTemplate });
    const result = await IncludeExpander.expand(scenario, loader);

    expect(result['includes']).toBeUndefined();
    const steps = result['steps'] as Record<string, unknown>[];
    expect(steps).toHaveLength(2);
    expect(steps[0]['name']).toBe('seed-customer');
    expect((steps[0]['params'] as Record<string, unknown>)['name']).toBe('Alice');
    expect(steps[1]['name']).toBe('main-step');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/yaml-core/src/include-expander.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Write IncludeExpander implementation**

```typescript
// include-expander.ts
import { parse } from 'yaml';
import { VariableResolver } from './variable-resolver.js';
import { ParameterValidator } from './parameter-validator.js';
import { isTruthy } from './truthiness.js';
import type { YamlModuleParameter, ParameterType } from './types.js';

export type TemplateLoader = (path: string) => Promise<string>;

export interface IncludeDirective {
  file: string;
  params?: Record<string, unknown>;
}

interface RawParamDescriptor {
  name: string;
  type?: string;
  required?: boolean;
  default?: unknown;
  enum?: unknown[];
}

function toModuleParams(
  raw: RawParamDescriptor[],
): Record<string, YamlModuleParameter> {
  const result: Record<string, YamlModuleParameter> = {};
  for (const p of raw) {
    const type = ((p.type ?? 'string').toUpperCase()) as ParameterType;
    result[p.name] = {
      type,
      required: p.required ?? false,
      defaultValue: p.default !== undefined ? String(p.default) : undefined,
      allowedValues: p.enum?.map(String),
    };
  }
  return result;
}

function toStringParams(
  params: Record<string, unknown> | undefined,
): Record<string, string> {
  if (!params) return {};
  const result: Record<string, string> = {};
  for (const [k, v] of Object.entries(params)) {
    result[k] = String(v);
  }
  return result;
}

function resolveSteps(
  steps: Record<string, unknown>[],
  resolver: VariableResolver,
): Record<string, unknown>[] {
  return steps.map(step =>
    resolver.resolveMap(step, 'include-step'),
  );
}

function filterByWhen(
  steps: Record<string, unknown>[],
): Record<string, unknown>[] {
  return steps.filter(step => {
    const when = step['when'];
    if (when === undefined || when === null) return true;
    if (typeof when === 'boolean') return when;
    if (typeof when === 'string') {
      if (when === '' || when === 'false' || when === 'no'
        || when === 'off' || when === 'n' || when === '0') return false;
      try { return isTruthy(when); } catch { return true; }
    }
    return true;
  });
}

export class IncludeExpander {

  static async expand(
    parsed: Record<string, unknown>,
    loader: TemplateLoader,
    ancestors?: Set<string>,
  ): Promise<Record<string, unknown>> {
    const ancestorSet = ancestors ?? new Set<string>();
    const result = { ...parsed };

    // Expand top-level includes
    if (Array.isArray(result['includes'])) {
      const includes = result['includes'] as IncludeDirective[];
      const expandedSteps = await IncludeExpander.expandIncludes(
        includes, loader, ancestorSet,
      );
      const existingSteps = Array.isArray(result['steps'])
        ? (result['steps'] as Record<string, unknown>[])
        : [];
      result['steps'] = [...expandedSteps, ...existingSteps];
      delete result['includes'];
    }

    // Expand section-level includes
    if (Array.isArray(result['sections'])) {
      result['sections'] = await Promise.all(
        (result['sections'] as Record<string, unknown>[]).map(
          async (section) => {
            if (!Array.isArray(section['includes'])) return section;
            const sectionResult = { ...section };
            const includes = sectionResult['includes'] as IncludeDirective[];
            const expandedSteps = await IncludeExpander.expandIncludes(
              includes, loader, ancestorSet,
            );
            const existingSteps = Array.isArray(sectionResult['steps'])
              ? (sectionResult['steps'] as Record<string, unknown>[])
              : [];
            sectionResult['steps'] = [...expandedSteps, ...existingSteps];
            delete sectionResult['includes'];
            return sectionResult;
          },
        ),
      );
    }

    return result;
  }

  private static async expandIncludes(
    includes: IncludeDirective[],
    loader: TemplateLoader,
    ancestors: Set<string>,
  ): Promise<Record<string, unknown>[]> {
    const allSteps: Record<string, unknown>[] = [];

    for (const include of includes) {
      if (ancestors.has(include.file)) {
        const cycle = [...ancestors, include.file].join(' → ');
        throw new Error(`Circular include detected: ${cycle}`);
      }

      const templateYaml = await loader(include.file);
      const template = parse(templateYaml) as Record<string, unknown>;

      // Validate params
      const declaredRaw = Array.isArray(template['params'])
        ? (template['params'] as RawParamDescriptor[])
        : [];
      const declared = toModuleParams(declaredRaw);
      const provided = toStringParams(include.params);

      // Filter out unknown-param violations (warn, don't error)
      const violations = ParameterValidator.validate(declared, provided);
      const errors = violations.filter(v => v.constraint !== 'unknown');
      if (errors.length > 0) {
        const msgs = errors.map(v => v.message).join('; ');
        throw new Error(`Include '${include.file}': ${msgs}`);
      }

      // Resolve ${params.name} in template steps
      const resolver = VariableResolver.forParams(
        declared, provided, new Set<string>(),
      );

      const rawSteps = Array.isArray(template['steps'])
        ? (template['steps'] as Record<string, unknown>[])
        : [];

      const resolved = resolveSteps(rawSteps, resolver);
      const filtered = filterByWhen(resolved);

      // Recursive expansion for nested includes
      if (Array.isArray(template['includes'])) {
        const nestedAncestors = new Set(ancestors);
        nestedAncestors.add(include.file);
        const nested = { ...template, steps: filtered };
        const expanded = await IncludeExpander.expand(
          nested, loader, nestedAncestors,
        );
        allSteps.push(
          ...(expanded['steps'] as Record<string, unknown>[]),
        );
      } else {
        allSteps.push(...filtered);
      }
    }

    return allSteps;
  }
}
```

Note: `yaml` is already a dependency of the pages monorepo (used by
pages-aria). However, yaml-core currently has zero runtime deps except
zod. The `parse` function from `yaml` is needed to parse template YAML
strings. Check if `yaml` is already available to yaml-core — if not,
the caller should pre-parse and pass objects. **Alternative:** accept
raw YAML string OR pre-parsed object in the loader return type, or have
the loader return parsed objects. Since yaml-core should stay minimal,
**the loader should return the parsed YAML object** (the caller handles
YAML parsing):

```typescript
export type TemplateLoader = (path: string) => Promise<Record<string, unknown>>;
```

This keeps `yaml` out of yaml-core. Update the implementation
accordingly — remove the `parse()` import and call.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/yaml-core/src/include-expander.test.ts`
Expected: PASS

Update the test's `mockLoader` to return pre-parsed objects instead of
YAML strings:

```typescript
import { parse } from 'yaml';

function mockLoader(files: Record<string, string>): TemplateLoader {
  return async (path: string) => {
    const content = files[path];
    if (!content) throw new Error(`Template not found: ${path}`);
    return parse(content) as Record<string, unknown>;
  };
}
```

The `yaml` package stays in the test file only (it's a devDependency
of the monorepo).

- [ ] **Step 5: Write test — multiple includes preserve order**

```typescript
it('multiple includes prepend in declaration order', async () => {
  const scenario = {
    scenario: 'demo',
    includes: [
      { file: 'a.yaml', params: { customer: 'Alice' } },
      { file: 'b.yaml', params: { customer: 'Bob' } },
    ],
    steps: [{ name: 'main', step: 'action' }],
  };

  const loader = mockLoader({
    'a.yaml': seedTemplate,
    'b.yaml': seedTemplate,
  });
  const result = await IncludeExpander.expand(scenario, loader);
  const steps = result['steps'] as Record<string, unknown>[];

  expect(steps).toHaveLength(3);
  expect((steps[0]['params'] as Record<string, unknown>)['name']).toBe('Alice');
  expect((steps[1]['params'] as Record<string, unknown>)['name']).toBe('Bob');
  expect(steps[2]['name']).toBe('main');
});
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/yaml-core/src/include-expander.test.ts`
Expected: PASS

- [ ] **Step 7: Write test — when: filtering excludes falsy steps**

```typescript
const conditionalTemplate = `
params:
  - name: priority
    type: string
    required: false
steps:
  - name: always-included
    step: always
  - name: conditional-step
    when: "\${params.priority}"
    step: set-priority
    params:
      level: "\${params.priority}"
`;

it('when: filters out steps where condition is falsy', async () => {
  const scenario = {
    scenario: 'demo',
    includes: [{ file: 'cond.yaml', params: {} }],
    steps: [],
  };
  const loader = mockLoader({ 'cond.yaml': conditionalTemplate });
  const result = await IncludeExpander.expand(scenario, loader);
  const steps = result['steps'] as Record<string, unknown>[];

  expect(steps).toHaveLength(1);
  expect(steps[0]['name']).toBe('always-included');
});

it('when: keeps steps where condition is truthy', async () => {
  const scenario = {
    scenario: 'demo',
    includes: [{ file: 'cond.yaml', params: { priority: 'High' } }],
    steps: [],
  };
  const loader = mockLoader({ 'cond.yaml': conditionalTemplate });
  const result = await IncludeExpander.expand(scenario, loader);
  const steps = result['steps'] as Record<string, unknown>[];

  expect(steps).toHaveLength(2);
  expect(steps[1]['name']).toBe('conditional-step');
  expect((steps[1]['params'] as Record<string, unknown>)['level']).toBe('High');
});
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/yaml-core/src/include-expander.test.ts`
Expected: PASS

- [ ] **Step 9: Write test — missing required param throws**

```typescript
it('throws on missing required param', async () => {
  const scenario = {
    scenario: 'demo',
    includes: [{ file: 'seeds/base.yaml', params: {} }],
    steps: [],
  };
  const loader = mockLoader({ 'seeds/base.yaml': seedTemplate });

  await expect(IncludeExpander.expand(scenario, loader))
    .rejects.toThrow(/missing/i);
});
```

- [ ] **Step 10: Run test to verify it passes**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/yaml-core/src/include-expander.test.ts`
Expected: PASS

- [ ] **Step 11: Write test — default values applied**

```typescript
const defaultTemplate = `
params:
  - name: role
    type: string
    default: Viewer
steps:
  - name: set-role
    step: set-role
    params:
      role: "\${params.role}"
`;

it('applies default values when param omitted', async () => {
  const scenario = {
    scenario: 'demo',
    includes: [{ file: 'def.yaml', params: {} }],
    steps: [],
  };
  const loader = mockLoader({ 'def.yaml': defaultTemplate });
  const result = await IncludeExpander.expand(scenario, loader);
  const steps = result['steps'] as Record<string, unknown>[];

  expect(steps).toHaveLength(1);
  expect((steps[0]['params'] as Record<string, unknown>)['role']).toBe('Viewer');
});
```

- [ ] **Step 12: Run test to verify it passes**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/yaml-core/src/include-expander.test.ts`
Expected: PASS

- [ ] **Step 13: Write test — cycle detection**

```typescript
it('throws on circular include', async () => {
  const templateA = `
params: []
includes:
  - file: b.yaml
steps:
  - name: step-a
    step: action-a
`;
  const templateB = `
params: []
includes:
  - file: a.yaml
steps:
  - name: step-b
    step: action-b
`;
  const scenario = {
    scenario: 'demo',
    includes: [{ file: 'a.yaml' }],
    steps: [],
  };
  const loader = mockLoader({
    'a.yaml': templateA,
    'b.yaml': templateB,
  });

  await expect(IncludeExpander.expand(scenario, loader))
    .rejects.toThrow(/circular include/i);
});
```

- [ ] **Step 14: Run test to verify it passes**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/yaml-core/src/include-expander.test.ts`
Expected: PASS

- [ ] **Step 15: Write test — nested includes (non-circular)**

```typescript
it('expands nested includes recursively', async () => {
  const innerTemplate = `
params:
  - name: item
    type: string
    required: true
steps:
  - name: inner-step
    step: inner
    params:
      item: "\${params.item}"
`;
  const outerTemplate = `
params:
  - name: customer
    type: string
    required: true
includes:
  - file: inner.yaml
    params:
      item: "\${params.customer}"
steps:
  - name: outer-step
    step: outer
`;
  const scenario = {
    scenario: 'demo',
    includes: [{ file: 'outer.yaml', params: { customer: 'Alice' } }],
    steps: [{ name: 'main', step: 'main' }],
  };
  const loader = mockLoader({
    'outer.yaml': outerTemplate,
    'inner.yaml': innerTemplate,
  });
  const result = await IncludeExpander.expand(scenario, loader);
  const steps = result['steps'] as Record<string, unknown>[];

  expect(steps).toHaveLength(3);
  expect(steps[0]['name']).toBe('inner-step');
  expect((steps[0]['params'] as Record<string, unknown>)['item']).toBe('Alice');
  expect(steps[1]['name']).toBe('outer-step');
  expect(steps[2]['name']).toBe('main');
});
```

- [ ] **Step 16: Run test to verify it passes**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/yaml-core/src/include-expander.test.ts`
Expected: PASS

- [ ] **Step 17: Write test — section-level includes**

```typescript
it('expands section-level includes', async () => {
  const scenario = {
    scenario: 'tutorial',
    sections: [
      {
        title: 'Setup',
        includes: [{ file: 'seeds/base.yaml', params: { customer: 'Bob' } }],
        steps: [{ name: 'manual-step', step: 'manual' }],
      },
      {
        title: 'Main',
        steps: [{ name: 'untouched', step: 'action' }],
      },
    ],
  };
  const loader = mockLoader({ 'seeds/base.yaml': seedTemplate });
  const result = await IncludeExpander.expand(scenario, loader);
  const sections = result['sections'] as Record<string, unknown>[];

  const setupSteps = sections[0]['steps'] as Record<string, unknown>[];
  expect(setupSteps).toHaveLength(2);
  expect(setupSteps[0]['name']).toBe('seed-customer');
  expect(setupSteps[1]['name']).toBe('manual-step');

  const mainSteps = sections[1]['steps'] as Record<string, unknown>[];
  expect(mainSteps).toHaveLength(1);
  expect(mainSteps[0]['name']).toBe('untouched');
});
```

- [ ] **Step 18: Run test to verify it passes**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/yaml-core/src/include-expander.test.ts`
Expected: PASS

- [ ] **Step 19: Write test — no includes is a no-op**

```typescript
it('returns unchanged when no includes present', async () => {
  const scenario = {
    scenario: 'demo',
    steps: [{ name: 'only-step', step: 'action' }],
  };
  const loader = mockLoader({});
  const result = await IncludeExpander.expand(scenario, loader);

  expect(result['steps']).toHaveLength(1);
  expect((result['steps'] as Record<string, unknown>[])[0]['name']).toBe('only-step');
});
```

- [ ] **Step 20: Run test to verify it passes**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/yaml-core/src/include-expander.test.ts`
Expected: PASS

- [ ] **Step 21: Write test — template not found throws**

```typescript
it('throws when template not found', async () => {
  const scenario = {
    scenario: 'demo',
    includes: [{ file: 'missing.yaml' }],
    steps: [],
  };
  const loader = mockLoader({});

  await expect(IncludeExpander.expand(scenario, loader))
    .rejects.toThrow(/not found/i);
});
```

- [ ] **Step 22: Run test to verify it passes**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/yaml-core/src/include-expander.test.ts`
Expected: PASS

- [ ] **Step 23: Export from yaml-core index**

Add to `packages/yaml-core/src/index.ts`:

```typescript
export { IncludeExpander } from './include-expander.js';
export type { TemplateLoader, IncludeDirective } from './include-expander.js';
```

- [ ] **Step 24: Run full yaml-core test suite**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/yaml-core/`
Expected: All tests PASS

- [ ] **Step 25: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/210/pages add packages/yaml-core/src/include-expander.ts packages/yaml-core/src/include-expander.test.ts packages/yaml-core/src/index.ts
git -C /Users/mdproctor/claude/casehub/slots/210/pages commit -m "feat(#327): IncludeExpander — parameterized template expansion with cycle detection"
```

## Batch 2: TS parseScenario integration in pages-aria

### Task 2: Wire IncludeExpander into parseScenario

**Files:**
- Modify: `packages/pages-aria/src/scenario/parser.ts` (add loader param, async)
- Create: `packages/pages-aria/src/scenario/parser-includes.test.ts`
- Modify: `packages/pages-aria/src/scenario/types.ts` (re-export TemplateLoader if needed)

**Interfaces:**
- Consumes: `IncludeExpander.expand()` and `TemplateLoader` from
  `@casehubio/yaml-core`
- Produces: `parseScenario(yamlString, catalog, loader?)` — async
  overload

- [ ] **Step 1: Write failing test — parseScenario with loader expands includes**

```typescript
// parser-includes.test.ts
import { describe, it, expect } from 'vitest';
import { parseScenario } from './parser.js';
import { createScenarioCatalog } from './catalog-factory.js';
import { parse } from 'yaml';
import type { TemplateLoader } from '@casehubio/yaml-core';

describe('parseScenario with includes', () => {
  const catalog = createScenarioCatalog();

  const seedTemplate = `
params:
  - name: sender
    type: string
    required: true
steps:
  - name: seed-message
    step: seed-message
    delivery: graphql
    domain: connectors
    operation: injectChat
    params:
      sender: "\${params.sender}"
`;

  function mockLoader(files: Record<string, string>): TemplateLoader {
    return async (path: string) => {
      const content = files[path];
      if (!content) throw new Error(`Template not found: ${path}`);
      return parse(content) as Record<string, unknown>;
    };
  }

  it('expands includes before resolving steps', async () => {
    const yaml = `
scenario: include-demo
includes:
  - file: seeds/chat.yaml
    params:
      sender: Alice
steps:
  - name: main-step
    step: main-step
    click:
      role: button
      name: Submit
`;
    const loader = mockLoader({ 'seeds/chat.yaml': seedTemplate });
    const result = await parseScenario(yaml, catalog, loader);

    expect('steps' in result).toBe(true);
    if ('steps' in result) {
      expect(result.steps.length).toBeGreaterThanOrEqual(2);
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/pages-aria/src/scenario/parser-includes.test.ts`
Expected: FAIL — parseScenario doesn't accept loader param / isn't async

- [ ] **Step 3: Modify parseScenario to accept optional loader**

Update `packages/pages-aria/src/scenario/parser.ts`:

1. Add import: `import { IncludeExpander } from '@casehubio/yaml-core';`
   and `import type { TemplateLoader } from '@casehubio/yaml-core';`
2. Change function signature to async with optional loader:

```typescript
export async function parseScenario(
  yamlString: string,
  catalog: Catalog,
  loader?: TemplateLoader,
): Promise<Scenario> {
  let parsed = parse(yamlString) as Record<string, unknown>;

  // Include expansion phase — before step resolution
  if (loader) {
    parsed = await IncludeExpander.expand(parsed, loader);
  } else if (Array.isArray(parsed['includes'])) {
    throw new Error(
      "Scenario contains 'includes' but no template loader was provided",
    );
  }

  // ... rest of existing parsing logic unchanged
}
```

Note: Making `parseScenario` async is a breaking change for existing
callers. Check all call sites — they should already be in async
contexts (scenario-controller fetches YAML via HTTP). Add `await` at
each call site:
- `scenario-controller.ts` (`_startScript`)
- Any test files calling `parseScenario`

Update existing test files to await:
- `packages/pages-aria/src/scenario/scenario.test.ts`
- `packages/pages-aria/src/scenario/parser-orchestration.test.ts`
- Any other files importing `parseScenario`

Search with: `ide_find_references` on `parseScenario` to find all callers.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/pages-aria/src/scenario/parser-includes.test.ts`
Expected: PASS

- [ ] **Step 5: Write test — parseScenario without loader throws on includes**

```typescript
it('throws when includes present but no loader', async () => {
  const yaml = `
scenario: no-loader
includes:
  - file: missing.yaml
steps:
  - name: step
    step: step
    click:
      role: button
      name: Go
`;
  await expect(parseScenario(yaml, catalog))
    .rejects.toThrow(/no template loader/i);
});
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/pages-aria/src/scenario/parser-includes.test.ts`
Expected: PASS

- [ ] **Step 7: Run full pages-aria scenario test suite**

Run: `cd /Users/mdproctor/claude/casehub/slots/210/pages && npx vitest run packages/pages-aria/src/scenario/`
Expected: All tests PASS (existing tests now use async/await)

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/210/pages add packages/pages-aria/src/scenario/
git -C /Users/mdproctor/claude/casehub/slots/210/pages commit -m "feat(#327): wire IncludeExpander into parseScenario — async with optional loader"
```

## Batch 3: Java IncludeExpander in scenario module

### Task 3: Java IncludeExpander with param validation and cycle detection

**Files:**
- Create: `backend/scenario/src/main/java/io/casehub/pages/scenario/IncludeExpander.java`
- Create: `backend/scenario/src/test/java/io/casehub/pages/scenario/IncludeExpanderTest.java`

**Interfaces:**
- Consumes: `ParameterValidator.validateOrThrow()` from `io.casehub.yaml.core.module`,
  `VariableResolver.forParams()` from `io.casehub.yaml.core.resolver`,
  `Truthiness.evaluate()` from `io.casehub.yaml.core.condition`,
  `CallGraphValidator` pattern for cycle detection,
  `HierarchicalParser.parseParams()` pattern for param parsing,
  `ParamDescriptor` from scenario module
- Produces: `IncludeExpander(TemplateLoader).expand(JsonNode)`,
  `TemplateLoader` functional interface

- [ ] **Step 1: Write failing test — single include prepends steps**

```java
// IncludeExpanderTest.java
package io.casehub.pages.scenario;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import org.junit.jupiter.api.Test;

import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;

class IncludeExpanderTest {

    private static final ObjectMapper YAML = new ObjectMapper(new YAMLFactory());

    private static final String SEED_TEMPLATE = """
            params:
              - name: customer
                type: string
                required: true
            steps:
              - name: seed-customer
                label: Seed customer
                target: browser
                commands:
                  - action: fill
                    target: {role: textbox, name: "Full Name"}
                    value: "${params.customer}"
            """;

    @FunctionalInterface
    interface TestLoader extends IncludeExpander.TemplateLoader {}

    private IncludeExpander.TemplateLoader mockLoader(
            java.util.Map<String, String> files) {
        return path -> {
            String content = files.get(path);
            if (content == null)
                throw new IllegalArgumentException(
                    "Template not found: " + path);
            return YAML.readTree(content);
        };
    }

    @Test
    void singleIncludePrependsSteps() throws Exception {
        String scenario = """
                scenario: demo
                includes:
                  - file: seeds/base.yaml
                    params:
                      customer: Alice
                steps:
                  - name: main-step
                    label: Main
                    target: browser
                    commands:
                      - action: click
                        target: {role: button, name: Done}
                """;

        var expander = new IncludeExpander(
            mockLoader(java.util.Map.of("seeds/base.yaml", SEED_TEMPLATE)));
        JsonNode result = expander.expand(YAML.readTree(scenario));

        assertFalse(result.has("includes"));
        JsonNode steps = result.get("steps");
        assertEquals(2, steps.size());
        assertEquals("seed-customer", steps.get(0).get("name").asText());
        assertEquals("Alice",
            steps.get(0).get("commands").get(0).get("value").asText());
        assertEquals("main-step", steps.get(1).get("name").asText());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl backend/scenario -Dtest=IncludeExpanderTest test`
Expected: FAIL — class not found

- [ ] **Step 3: Write IncludeExpander implementation**

```java
// IncludeExpander.java
package io.casehub.pages.scenario;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import io.casehub.yaml.core.condition.Truthiness;
import io.casehub.yaml.core.module.ParameterValidator;
import io.casehub.yaml.core.module.ParameterType;
import io.casehub.yaml.core.module.YamlModuleParameter;
import io.casehub.yaml.core.resolver.VariableResolver;

import java.io.IOException;
import java.util.*;

public final class IncludeExpander {

    @FunctionalInterface
    public interface TemplateLoader {
        JsonNode load(String path) throws IOException;
    }

    private final TemplateLoader loader;

    public IncludeExpander(TemplateLoader loader) {
        this.loader = Objects.requireNonNull(loader);
    }

    public JsonNode expand(JsonNode root) {
        return expand(root, new LinkedHashSet<>());
    }

    public JsonNode expand(JsonNode root, Set<String> ancestors) {
        ObjectNode result = root.deepCopy();

        if (result.has("includes") && result.get("includes").isArray()) {
            List<JsonNode> expandedSteps = expandIncludes(
                result.get("includes"), ancestors);
            ArrayNode mergedSteps = result.arrayNode();
            expandedSteps.forEach(mergedSteps::add);
            if (result.has("steps") && result.get("steps").isArray()) {
                result.get("steps").forEach(mergedSteps::add);
            }
            result.set("steps", mergedSteps);
            result.remove("includes");
        }

        if (result.has("sections") && result.get("sections").isArray()) {
            ArrayNode sections = result.arrayNode();
            for (JsonNode sec : result.get("sections")) {
                if (sec.has("includes") && sec.get("includes").isArray()) {
                    ObjectNode sectionCopy = sec.deepCopy();
                    List<JsonNode> expandedSteps = expandIncludes(
                        sectionCopy.get("includes"), ancestors);
                    ArrayNode mergedSteps = result.arrayNode();
                    expandedSteps.forEach(mergedSteps::add);
                    if (sectionCopy.has("steps")
                            && sectionCopy.get("steps").isArray()) {
                        sectionCopy.get("steps").forEach(mergedSteps::add);
                    }
                    sectionCopy.set("steps", mergedSteps);
                    sectionCopy.remove("includes");
                    sections.add(sectionCopy);
                } else {
                    sections.add(sec);
                }
            }
            result.set("sections", sections);
        }

        return result;
    }

    private List<JsonNode> expandIncludes(
            JsonNode includes, Set<String> ancestors) {
        List<JsonNode> allSteps = new ArrayList<>();

        for (JsonNode include : includes) {
            String file = include.get("file").asText();

            if (ancestors.contains(file)) {
                List<String> cycle = new ArrayList<>(ancestors);
                cycle.add(file);
                throw new IllegalArgumentException(
                    "Circular include detected: "
                    + String.join(" → ", cycle));
            }

            JsonNode template;
            try {
                template = loader.load(file);
            } catch (IOException e) {
                throw new IllegalArgumentException(
                    "Include failed: template '" + file
                    + "' not found", e);
            }

            // Parse and validate params
            Map<String, YamlModuleParameter> declared =
                parseTemplateParams(template);
            Map<String, String> provided =
                extractCallerParams(include);

            var violations = ParameterValidator.validate(
                declared, provided);
            var errors = violations.stream()
                .filter(v -> !"unknown".equals(v.constraint()))
                .toList();
            if (!errors.isEmpty()) {
                String msgs = errors.stream()
                    .map(io.casehub.yaml.core.module
                         .ParameterViolation::message)
                    .reduce((a, b) -> a + "; " + b).orElse("");
                throw new IllegalArgumentException(
                    "Include '" + file + "': " + msgs);
            }

            // Resolve ${params.name}
            VariableResolver resolver = VariableResolver.forParams(
                declared, provided, Set.of());

            // Process steps
            if (template.has("steps") && template.get("steps").isArray()) {
                for (JsonNode step : template.get("steps")) {
                    JsonNode resolved = resolveNode(step, resolver);
                    if (shouldInclude(resolved)) {
                        allSteps.add(resolved);
                    }
                }
            }

            // Recursive expansion for nested includes
            if (template.has("includes")
                    && template.get("includes").isArray()) {
                Set<String> nestedAncestors = new LinkedHashSet<>(ancestors);
                nestedAncestors.add(file);
                ObjectNode nested = template.deepCopy();
                ArrayNode nestedSteps = nested.arrayNode();
                allSteps.forEach(nestedSteps::add);
                nested.set("steps", nestedSteps);
                JsonNode expanded = expand(nested, nestedAncestors);
                allSteps.clear();
                if (expanded.has("steps")) {
                    expanded.get("steps").forEach(allSteps::add);
                }
            }
        }

        return allSteps;
    }

    private Map<String, YamlModuleParameter> parseTemplateParams(
            JsonNode template) {
        if (!template.has("params")
                || !template.get("params").isArray()) {
            return Map.of();
        }
        Map<String, YamlModuleParameter> result = new LinkedHashMap<>();
        for (JsonNode p : template.get("params")) {
            String name = p.path("name").asText();
            String typeStr = p.path("type").asText("string");
            ParameterType type = ParameterType.fromString(typeStr);
            boolean required = p.path("required").asBoolean(false);
            String defaultValue = p.has("default")
                ? p.get("default").asText() : null;
            List<String> allowed = new ArrayList<>();
            if (p.has("enum")) {
                for (JsonNode e : p.get("enum")) {
                    allowed.add(e.asText());
                }
            }
            result.put(name, YamlModuleParameter.builder()
                .type(type).required(required)
                .defaultValue(defaultValue)
                .allowedValues(allowed).build());
        }
        return result;
    }

    @SuppressWarnings("unchecked")
    private Map<String, String> extractCallerParams(JsonNode include) {
        if (!include.has("params")) return Map.of();
        Map<String, String> result = new LinkedHashMap<>();
        var it = include.get("params").fields();
        while (it.hasNext()) {
            var entry = it.next();
            result.put(entry.getKey(), entry.getValue().asText());
        }
        return result;
    }

    private JsonNode resolveNode(JsonNode node, VariableResolver resolver) {
        if (node.isTextual()) {
            String text = node.asText();
            if (text.contains("${")) {
                String resolved = resolver.resolveString(text, "include");
                return node.nodeFactory().textNode(resolved);
            }
            return node;
        }
        if (node.isObject()) {
            ObjectNode result = node.deepCopy();
            var fields = result.fields();
            List<Map.Entry<String, JsonNode>> entries = new ArrayList<>();
            while (fields.hasNext()) entries.add(fields.next());
            for (var entry : entries) {
                result.set(entry.getKey(),
                    resolveNode(entry.getValue(), resolver));
            }
            return result;
        }
        if (node.isArray()) {
            ArrayNode result = node.arrayNode();
            for (JsonNode element : node) {
                result.add(resolveNode(element, resolver));
            }
            return result;
        }
        return node;
    }

    private boolean shouldInclude(JsonNode step) {
        if (!step.has("when")) return true;
        String when = step.get("when").asText();
        if (when.isEmpty()) return false;
        try {
            return Truthiness.evaluate(when);
        } catch (Exception e) {
            return true;
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode -pl backend/scenario -Dtest=IncludeExpanderTest test`
Expected: PASS

- [ ] **Step 5: Write tests — cycle detection, missing param, when filtering, defaults, nested**

Add to `IncludeExpanderTest.java`:

```java
@Test
void throwsOnCircularInclude() throws Exception {
    String templateA = """
            params: []
            includes:
              - file: b.yaml
            steps:
              - name: step-a
                label: A
                target: browser
                commands: []
            """;
    String templateB = """
            params: []
            includes:
              - file: a.yaml
            steps:
              - name: step-b
                label: B
                target: browser
                commands: []
            """;
    String scenario = """
            scenario: demo
            includes:
              - file: a.yaml
            steps: []
            """;
    var expander = new IncludeExpander(
        mockLoader(java.util.Map.of("a.yaml", templateA,
                                     "b.yaml", templateB)));
    assertThrows(IllegalArgumentException.class,
        () -> expander.expand(YAML.readTree(scenario)));
}

@Test
void throwsOnMissingRequiredParam() throws Exception {
    String scenario = """
            scenario: demo
            includes:
              - file: seeds/base.yaml
                params: {}
            steps: []
            """;
    var expander = new IncludeExpander(
        mockLoader(java.util.Map.of("seeds/base.yaml", SEED_TEMPLATE)));
    assertThrows(IllegalArgumentException.class,
        () -> expander.expand(YAML.readTree(scenario)));
}

@Test
void whenFilteringExcludesFalsySteps() throws Exception {
    String template = """
            params:
              - name: priority
                type: string
            steps:
              - name: always
                label: Always
                target: browser
                commands: []
              - name: conditional
                when: "${params.priority}"
                label: Conditional
                target: browser
                commands: []
            """;
    String scenario = """
            scenario: demo
            includes:
              - file: cond.yaml
                params: {}
            steps: []
            """;
    var expander = new IncludeExpander(
        mockLoader(java.util.Map.of("cond.yaml", template)));
    JsonNode result = expander.expand(YAML.readTree(scenario));

    assertEquals(1, result.get("steps").size());
    assertEquals("always",
        result.get("steps").get(0).get("name").asText());
}

@Test
void defaultValuesApplied() throws Exception {
    String template = """
            params:
              - name: role
                type: string
                default: Viewer
            steps:
              - name: set-role
                label: Set role
                target: browser
                commands:
                  - action: fill
                    value: "${params.role}"
            """;
    String scenario = """
            scenario: demo
            includes:
              - file: def.yaml
                params: {}
            steps: []
            """;
    var expander = new IncludeExpander(
        mockLoader(java.util.Map.of("def.yaml", template)));
    JsonNode result = expander.expand(YAML.readTree(scenario));

    assertEquals("Viewer",
        result.get("steps").get(0).get("commands")
              .get(0).get("value").asText());
}

@Test
void nestedIncludesExpandRecursively() throws Exception {
    String inner = """
            params:
              - name: item
                type: string
                required: true
            steps:
              - name: inner-step
                label: Inner
                target: browser
                commands:
                  - action: fill
                    value: "${params.item}"
            """;
    String outer = """
            params:
              - name: customer
                type: string
                required: true
            includes:
              - file: inner.yaml
                params:
                  item: "${params.customer}"
            steps:
              - name: outer-step
                label: Outer
                target: browser
                commands: []
            """;
    String scenario = """
            scenario: demo
            includes:
              - file: outer.yaml
                params:
                  customer: Alice
            steps:
              - name: main
                label: Main
                target: browser
                commands: []
            """;
    var expander = new IncludeExpander(
        mockLoader(java.util.Map.of("outer.yaml", outer,
                                     "inner.yaml", inner)));
    JsonNode result = expander.expand(YAML.readTree(scenario));

    assertEquals(3, result.get("steps").size());
    assertEquals("inner-step",
        result.get("steps").get(0).get("name").asText());
    assertEquals("Alice",
        result.get("steps").get(0).get("commands")
              .get(0).get("value").asText());
    assertEquals("outer-step",
        result.get("steps").get(1).get("name").asText());
    assertEquals("main",
        result.get("steps").get(2).get("name").asText());
}
```

- [ ] **Step 6: Run all tests**

Run: `mvn --batch-mode -pl backend/scenario -Dtest=IncludeExpanderTest test`
Expected: All PASS

- [ ] **Step 7: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/210/pages add backend/scenario/src/main/java/io/casehub/pages/scenario/IncludeExpander.java backend/scenario/src/test/java/io/casehub/pages/scenario/IncludeExpanderTest.java
git -C /Users/mdproctor/claude/casehub/slots/210/pages commit -m "feat(#327): Java IncludeExpander — param validation, when filtering, cycle detection"
```

## Batch 4: Java ScenarioCompiler integration

### Task 4: Wire IncludeExpander into ScenarioCompiler

**Files:**
- Modify: `backend/scenario/src/main/java/io/casehub/pages/scenario/ScenarioCompiler.java`
- Modify: `backend/scenario/src/test/java/io/casehub/pages/scenario/ScenarioCompilerCallTest.java`
  (add include expansion tests)

**Interfaces:**
- Consumes: `IncludeExpander(loader).expand(root)` from Task 3,
  `ScenarioCompiler.compile(yaml, params, scriptResolver)` existing API
- Produces: `ScenarioCompiler.compile(yaml, params, scriptResolver, templateLoader)`
  — new overload with optional template loader

- [ ] **Step 1: Write failing test — compile with includes expands before call resolution**

Add to `ScenarioCompilerCallTest.java` (or create a new
`ScenarioCompilerIncludeTest.java`):

```java
@Test
void compileExpandsIncludesBeforeCalls() throws Exception {
    String seedTemplate = """
            params:
              - name: user
                type: string
                required: true
            steps:
              - name: create-user
                label: Create user
                target: browser
                commands:
                  - action: fill
                    target: {role: textbox, name: "Name"}
                    value: "${params.user}"
            """;
    String scenario = """
            scenario: with-include
            includes:
              - file: seeds/user.yaml
                params:
                  user: Alice
            steps:
              - name: final-step
                label: Done
                target: browser
                commands:
                  - action: click
                    target: {role: button, name: Done}
            """;

    ObjectMapper yaml = new ObjectMapper(new YAMLFactory());
    IncludeExpander.TemplateLoader loader = path ->
        yaml.readTree(seedTemplate);

    CompiledScenario compiled = ScenarioCompiler.compile(
        scenario, Map.of(), name -> Optional.empty(), loader);

    assertEquals(2, compiled.steps().size());
    assertEquals("create-user", compiled.steps().get(0).name());
    assertEquals("final-step", compiled.steps().get(1).name());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode -pl backend/scenario -Dtest=ScenarioCompilerCallTest#compileExpandsIncludesBeforeCalls test`
Expected: FAIL — no overload with TemplateLoader

- [ ] **Step 3: Add TemplateLoader overload to ScenarioCompiler**

Add new `compile` overload in `ScenarioCompiler.java`:

```java
public static CompiledScenario compile(
        String yaml, Map<String, String> callerParams,
        Function<String, Optional<String>> scriptResolver,
        IncludeExpander.TemplateLoader templateLoader) {

    ObjectMapper yamlMapper = new ObjectMapper(
        new com.fasterxml.jackson.dataformat.yaml.YAMLFactory());
    JsonNode root;
    try {
        root = yamlMapper.readTree(yaml);
    } catch (IOException e) {
        throw new IllegalArgumentException(
            "Failed to parse scenario YAML", e);
    }

    // Include expansion — before all other processing
    if (templateLoader != null && root.has("includes")) {
        IncludeExpander expander = new IncludeExpander(templateLoader);
        root = expander.expand(root);
    }

    // Continue with existing compile logic using the expanded YAML
    return compile(root.toString(), callerParams, scriptResolver);
}
```

Note: This re-serialises the expanded JSON back to a string and passes
it to the existing `compile(String, ...)`. This is simple but
inefficient. A cleaner approach is to extract the
`HierarchicalParser.parse()` call and work on the `JsonNode` directly.
Prefer the re-serialise approach for correctness first; refactor to
direct `JsonNode` flow if performance matters.

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode -pl backend/scenario -Dtest=ScenarioCompilerCallTest#compileExpandsIncludesBeforeCalls test`
Expected: PASS

- [ ] **Step 5: Run full scenario test suite**

Run: `mvn --batch-mode -pl backend/scenario test`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/210/pages add backend/scenario/src/main/java/io/casehub/pages/scenario/ScenarioCompiler.java backend/scenario/src/test/java/io/casehub/pages/scenario/ScenarioCompilerCallTest.java
git -C /Users/mdproctor/claude/casehub/slots/210/pages commit -m "feat(#327): wire IncludeExpander into ScenarioCompiler — expand before call resolution"
```

## References

- [2026-10-02-scenario-includes-design.md] — design spec
- packages/yaml-core/src/variable-resolver.ts — VariableResolver.forParams()
- packages/yaml-core/src/parameter-validator.ts — ParameterValidator.validate()
- packages/yaml-core/src/truthiness.ts — isTruthy()
- packages/yaml-core/src/import-expander.ts — existing expansion pattern
- packages/pages-aria/src/scenario/parser.ts — parseScenario integration point
- backend/scenario/src/main/java/.../ScenarioCompiler.java — Java integration
- backend/scenario/src/main/java/.../CallGraphValidator.java — cycle detection pattern
- backend/scenario/src/main/java/.../ParamDescriptor.java — param schema
- casehubio/casehub-pages#327 — focal issue
- casehubio/platform#502 — epic
