# Design: Complete Type Unification — casehub-pages#508

## Summary

Eliminate remaining type name drift and YAML ceremony divergence between
the Java and TS YAML runtimes. Three work streams: platform type renames,
ceremony elimination (inline action resolution), and front matter format
for scenario documents.

## Platform — Type Renames

### StepWalker → Walker

Rename `StepWalker` class, test, and all references in `yaml-step-runtime`.

| Current | Target |
|---------|--------|
| `StepWalker.java` | `Walker.java` |
| `StepWalkerTest.java` | `WalkerTest.java` |
| All `StepWalker.resolve()` call sites | `Walker.resolve()` |
| Logger name | `Walker.class.getName()` |

The TS side already uses `Walker` (see `walker.ts:184`).

### YamlStepDefinitionSource → YamlDefinitionSource

Rename class and all references in `yaml-step-runtime`.

| Current | Target |
|---------|--------|
| `YamlStepDefinitionSource.java` | `YamlDefinitionSource.java` |
| All construction/reference sites | Updated |

### Test file renames in yaml-core

These tests reference classes that were already renamed (`StepDefinitionParser`
→ `DeclarationParser`, `StepDefinition` → `Declaration`). Only the test file
names are stale.

| Current | Target |
|---------|--------|
| `StepDefinitionParserTest.java` | `DeclarationParserTest.java` |
| `StepDefinitionTest.java` | `DeclarationTest.java` |

### work.progress.StepDefinition — out of scope

Confirmed not present in this repo. Different domain (casehub-work).

## Platform — Ceremony Elimination

### Current behavior (Java StepWalker)

Match cases use `do:` wrapper:
```yaml
match: ${status}
cases:
  - pattern: "active"
    do:
      - process: { command: "activate.sh" }
```

Select branches use `do:` wrapper:
```yaml
select:
  - subscribe: events
    do:
      - process: { command: "handle.sh" }
```

Both already reject `steps:` with an error message pointing to `do:`.

### Target behavior (TS Walker)

Match cases use inline action resolution:
```yaml
match: ${status}
cases:
  - pattern: "active"
    process: { command: "activate.sh" }
```

Select branches use inline action resolution:
```yaml
select:
  - subscribe: events
    process: { command: "handle.sh" }
```

Both `steps` and `do` are rejected via `REMOVED_KEYS`.

### Implementation

1. **Add `REMOVED_KEYS`** — `Set.of("steps", "do")`. Check at top of
   `resolveOne()`, throw with message: `"'${key}' is no longer valid —
   use inline sibling keys, or 'block' for multiple actions"`.

2. **Add `stripKeys()`** — utility method matching TS `Walker.stripKeys()`:
   ```java
   private static Map<String, Object> stripKeys(
       Map<String, Object> map, Set<String> keysToStrip) {
       var result = new LinkedHashMap<String, Object>();
       for (var e : map.entrySet()) {
           if (!keysToStrip.contains(e.getKey())) {
               result.put(e.getKey(), e.getValue());
           }
       }
       return result;
   }
   ```

3. **Modify `resolveMatchCases()`** — for non-default cases, strip
   `pattern`/`guard`/`when` keys and resolve the remainder as a single
   step via `resolveOne()`:
   ```java
   var rest = stripKeys(caseMap, Set.of("pattern", "when", "guard"));
   var caseSteps = rest.isEmpty()
       ? List.<ResolvedStep>of()
       : List.of(resolveOne(rest, registry, i, depth + 1, casePath, seenNames));
   ```

4. **Modify `resolveSelectBranches()`** — strip `subscribe`/`wait` keys,
   resolve remainder as a single step via `resolveOne()`:
   ```java
   var rest = stripKeys(branchMap, Set.of("subscribe", "wait"));
   var branchSteps = rest.isEmpty()
       ? List.<ResolvedStep>of()
       : List.of(resolveOne(rest, registry, 0, depth + 1, branchPath, seenNames));
   ```

5. **Update tests** — rewrite 5 test cases in `WalkerTest.java` (renamed
   from `StepWalkerTest`) to use inline action format instead of `do:`.

### Multiple actions per branch

When a match case or select branch needs multiple actions, use `block:`:
```yaml
match: ${status}
cases:
  - pattern: "active"
    block:
      - process: { command: "activate.sh" }
      - assert: { expected: "done" }
```

This matches the TS behavior. The `block:` key is a structural keyword
already handled by `resolveOne()`.

## Front Matter Format

### Current scenario format

```yaml
scenario: onboarding
speed: 1.0
actor: user
states:
  - name: IDLE
    ...
```

Metadata and content in a single YAML document.

### Target format

```yaml
scenario: onboarding
speed: 1.0
actor: user
---
- process: { command: "init.sh" }
- assert: { expected: "ready" }
```

YAML multi-document: first document is metadata mapping, second document
is the bare action array (or states for state machine scenarios).

### Java implementation

`ScenarioParser` uses SnakeYAML. Change from `yaml.load()` to
`yaml.loadAll()`. First document → metadata. If a second document
exists, it's the action/state list. If not, fall back to current
single-document behavior for backward compatibility.

### TS implementation

Pages `parseScenario` uses js-yaml. Change from `load()` to `loadAll()`.
Same split logic.

### Scenario document updates (pages)

22 scenario files in pages need updating to use the front matter format.
Mechanical: move the action array after a `---` separator, keep metadata
before it.

Files: Coordination.ts (4), Data Delivery.ts (3), Flow Control.ts (9),
Composition.ts (3), Concurrency Patterns.ts (3).

## Pages — Type Name Drift

### Test descriptions

| File | Current | Target |
|------|---------|--------|
| `yaml-source.test.ts:86` | `StepDefinitionParser` in description | `DeclarationParser` |
| `script-source.test.ts:54` | `ValidatingStepAction` in description | `ValidatingAction` |

### Export drift in examples

| File | Current | Target |
|------|---------|--------|
| `casehub-entry.ts:42` | `export type { StepResult }` | `export type { Result }` |
| `casehub-entry.ts:54` | `import type { StepAction }` | `import type { Action }` |

Regenerate `examples/.typecheck/` after fixes.

### Schema drift

| File | Current | Target |
|------|---------|--------|
| `schema.ts:25` | `importSchema.steps` | `importSchema.actions` |

### Spec docs (historical)

| File | Items |
|------|-------|
| `docs/specs/issue-501-step-catalog-browser/decisions.md` | `<pages-step-catalog>`, `StepWalker`, `StructuralStepEvaluator` references |
| `docs/specs/issue-501-step-catalog-browser/2026-09-29-step-catalog-browser-design.md` | 9 old-name references |

These are historical docs — annotate with "renamed to X" rather than
rewrite, to preserve decision context.

## Execution Order

1. **Platform renames** — `StepWalker` → `Walker`, `YamlStepDefinitionSource` → `YamlDefinitionSource`, test file renames in yaml-core
2. **Platform ceremony elimination** — `REMOVED_KEYS`, `stripKeys()`, modify match/select resolution, update tests
3. **Platform front matter** — `ScenarioParser` multi-document support
4. **Pages type drift** — test descriptions, exports, schema
5. **Pages front matter + scenario updates** — TS parser `loadAll()`, update 22 scenario files
6. **Pages spec doc annotations** — historical doc updates
7. **Build verification** — full `mvn install` on platform, full test run on pages

## References

- casehub-pages#508 — epic issue
- casehub-pages#506 — type unification (landed)
- casehub/platform#496 — Java StepWalker alignment (scope expanded here)
- `walker.ts` — TS Walker with target behavior
- `StepWalker.java` — Java Walker, current state
- D37-D39 in decisions.md — design decisions for this issue
