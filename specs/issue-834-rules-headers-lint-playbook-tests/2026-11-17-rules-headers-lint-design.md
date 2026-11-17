# WS-5: Tutorial Headers and Assertion-Quality Lint for Playbook Tests

**Issue:** casehubio/platform#834
**Date:** 2026-11-17
**Status:** Draft

## Problem

The playbook examples serve as onboarding and teaching material, but the test coverage is shallow and the examples lack tutorial metadata.

**P22 finding:** Only 4 `.test.yaml` files exist for 70 playbook examples. 6 of 7 execution tests assert only `result.succeeded == true`. The catalog-parsing-gate expects 3 shipped examples to fail compilation. There is no structured metadata for learning path ordering or tutorial index generation.

## Scope

Four deliverables:

1. **Tutorial headers** — add `level`, `layer`, `teaches`, `builds-on` to every playbook's `meta:` block
2. **Assertion-quality lint** — a build-time check that rejects test files with only `succeeded`/`stepCount` assertions
3. **Category-level tests** — one `.test.yaml` per playbook category with behavioral assertions
4. **Gate cleanup** — fix the 3 failing examples so the catalog-parsing-gate expects 0 failures

### Out of scope

- R-ID rules and per-rule test cross-referencing (dropped — natural language rules with only structural lint enforcement don't carry their weight)
- Mutation checking (deferred per direction doc — language is still stabilising)
- Per-playbook test files (one per category is sufficient)

## 1. Tutorial Headers

### Schema

Add four fields to the `meta:` block in every `.playbook.yaml`:

```yaml
meta:
  title: "Retry"
  description: "..."
  tags: [retry, decorator, flow-control]
  level: 1
  layer: flow-control
  teaches: "retrying failed steps with configurable limits"
  builds-on: sequential
```

| Field | Type | Description |
|-------|------|-------------|
| `level` | integer 1-5 | Difficulty progression: 1=fundamental, 2=basic patterns, 3=intermediate, 4=advanced, 5=expert |
| `layer` | string | Matches the directory category name (flow-control, composition, coordination, etc.) |
| `teaches` | string | One-line description of the concept this playbook demonstrates |
| `builds-on` | string or list | Playbook name(s) the reader should understand first. Null for level-1 playbooks. |

### Level assignments

| Level | Meaning | Example categories |
|-------|---------|-------------------|
| 1 | Fundamental — single concept, no prerequisites | sequential, delay, click |
| 2 | Basic patterns — combines 2 concepts | retry, when-guard, if-else |
| 3 | Intermediate — structural composition | concurrent, parallel, try-catch, for-each |
| 4 | Advanced — coordination and concurrency | state-machine, correlation-scope, semaphore, channel |
| 5 | Expert — multi-primitive composition | combined-pipeline, heartbeat-monitor, timed-absence |

These are starting assignments. The exact level per playbook will be determined during implementation.

### Validation

The catalog-parsing-gate already validates all playbooks. Add validation that every `.playbook.yaml` has `level`, `layer`, and `teaches` in its meta block. `builds-on` is optional (null for level-1 fundamentals).

## 2. Assertion-Quality Lint

### Mechanism

A new Java test class in `playbooks/src/test/java/` that:

1. Scans all `.test.yaml` files under `playbooks/src/test/playbooks/`
2. Parses each test case's `steps` list
3. For each test case, collects all `assertThat` steps
4. Fails if a test case's only assertions are on `result.succeeded` or `result.stepCount` (or `result.valid` + `result.stepCount` for compilation tests)

### Opt-out

A test file can declare `lint: skip` in its top-level YAML to opt out:

```yaml
name: Some test file
lint: skip
tests:
  - name: "basic smoke test"
    steps:
      - run-playbook: ...
        capture: result
      - assertThat: result.succeeded
        equals: true
```

The lint test skips files with `lint: skip`. This exists for legitimate exceptions — WIP examples, TS-only playbooks where stub assertions are all that's meaningful, the catalog-parsing-gate itself.

### What counts as a "real" assertion

An assertion is considered non-trivial if `assertThat` targets anything other than:
- `result.succeeded`
- `result.stepCount`
- `result.valid`

Examples of real assertions:
- `assertThat: result.output.response` — behavioral outcome
- `assertThat: result.stateMachines.X` — orchestration state
- `assertThat: result.retryCount` — processing metric
- `assertThat: result.error` — error content verification
- `assertThat: result.pools.X.maxActive` — structural property

### Build integration

The lint runs as a standard JUnit test (`@Test`) in the playbooks module. It fails with a descriptive message listing every test case that lacks behavioral assertions, so the author can see the full picture at once.

## 3. Category-Level Tests

### Structure

One `.test.yaml` per playbook category directory:

| Category | Test file | Playbooks covered |
|----------|-----------|-------------------|
| flow-control | `flow-control/execution.test.yaml` | 12 |
| step-workflows | `step-workflows/execution.test.yaml` | 13 |
| composition | `composition/execution.test.yaml` | 9 |
| concurrency-patterns | `concurrency-patterns/execution.test.yaml` | 8 |
| coordination | `coordination/execution.test.yaml` | 4 |
| coordination-primitives | `coordination-primitives/execution.test.yaml` | 6 |
| invoke-bindings | `invoke-bindings/execution.test.yaml` | 6 |
| data-delivery | `data-delivery/execution.test.yaml` | 3 |
| simulation | (existing — upgrade assertions) | 1 |
| agent-interaction-patterns | (existing — upgrade assertions) | 8 |

### Test design philosophy

Tests are **teaching documentation**, not verification checklists. Each assertion should illuminate a behavior for the reader.

**Good** (teaches the reader something):
```yaml
- name: "retry re-executes failed step up to N times"
  steps:
    - run-playbook: .../retry.playbook.yaml
      capture: result
    - assertThat: result.output.retryCount
      equals: 3
```

**Bad** (tells the reader nothing):
```yaml
- name: "retry playbook works"
  steps:
    - run-playbook: .../retry.playbook.yaml
      capture: result
    - assertThat: result.succeeded
      equals: true
```

Not every playbook in a category needs an individual test. The category test covers representative examples — the ones that best illustrate the category's teaching points. A `succeeded` assertion can accompany a behavioral assertion as a secondary check, but it must not be the only assertion.

### Result enrichment

To enable behavioral assertions, enrich the `run-playbook` result map to include orchestration state when available:

| Key | Source | Example assertion |
|-----|--------|-------------------|
| `result.output.*` | Playbook output variables | `result.output.response` |
| `result.stateMachines.*` | State machine final states | `result.stateMachines.order` |
| `result.counters.*` | Counter primitive final values | `result.counters.attempts` |
| `result.flags.*` | Flag primitive final states | `result.flags.ready` |
| `result.retryCount` | Retry decorator execution count | `result.retryCount` |
| `result.error` | Error message on failure | `result.error` |
| `result.stepNames` | Executed step names (from validate-playbook) | `result.stepNames` |

Where runner enrichment isn't sufficient, individual playbooks can add explicit output steps to surface domain-specific outcomes.

## 4. Gate Cleanup

Three playbooks currently fail compilation in the catalog-parsing-gate:

| Playbook | Failure reason | Fix |
|----------|---------------|-----|
| `composition/modules.playbook.yaml` | Import deserialization | Fix the YAML structure or parser |
| `invoke-bindings/rest.playbook.yaml` | `headers` sibling key | Fix the key structure |
| `agent-interaction-patterns/08-structured-output.playbook.yaml` | `response-format` sibling key | Fix the key structure |

After fixing, update the gate assertion from `hasSize: 3` to `hasSize: 0`.

## Implementation Order

1. Fix the 3 failing playbooks (gate cleanup)
2. Update catalog-parsing-gate to expect 0 failures
3. Add tutorial header fields to all 70 playbooks
4. Add header validation to the catalog-parsing-gate
5. Enrich run-playbook result map with orchestration state
6. Write category-level test files with behavioral assertions
7. Implement assertion-quality lint
8. Upgrade existing test files (agent-interaction-patterns, simulation) to pass the lint

## References

- casehubio/platform#834 — this issue
- casehubio/platform#827 — parent epic (playbook language direction)
- casehubio/parent#540 — direction doc
- `playbook-direction.md` WS-5 section — original scope (rules headers + lint)
- `code-review-notes.md` P22 — gate test findings
- `ADR-0013` — trust model (orthogonal, not affected by this work)
- `playbooks/src/test/playbooks/catalog-parsing-gate.test.yaml` — existing gate
- `playbooks/src/test/playbooks/agent-interaction-patterns/execution.test.yaml` — existing shallow tests
- `playbooks/src/test/playbooks/simulation/order-lifecycle.test.yaml` — good test example (behavioral assertions)
- `yaml-test-core/src/main/java/io/casehub/yaml/test/ValidatePlaybookPlugin.java` — existing validation plugin
- `yaml-test-core/src/main/java/io/casehub/yaml/test/YamlTestExecutor.java` — test executor
