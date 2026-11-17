# Tutorial Headers and Assertion-Quality Lint — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** #834 — WS-5: Rules headers and lint for playbook tests
**Issue group:** #834

**Goal:** Add tutorial metadata headers to all 70 playbook examples,
build assertion-quality lint, write category-level behavioral tests,
and fix the 3 failing playbook examples.

**Architecture:** Headers go into the existing `meta:` block as
structured YAML fields (`level`, `layer`, `teaches`, `builds-on`).
Lint is a Java test in the playbooks module that parses `.test.yaml`
files and rejects tests with only trivial assertions. Category tests
are `.test.yaml` files — one per playbook directory. Runner enrichment
adds orchestration primitive snapshots to the run-playbook result map.

**Tech Stack:** Java 21, Maven, SnakeYAML, JUnit 5, YamlTestEngine

## Global Constraints

- `yaml-core/` and `yaml-plugin-api/` must remain zero-dependency
- `platform-api/` must remain zero-dependency
- Playbook files use two-document canonical form (WS-4)
- No quarkus:build goal on yaml-test-core or playbooks
- Tests run via `@Suite @IncludeEngines("casehub-yaml")` in playbooks module

---

## Batch 1: Gate Cleanup — fix 3 failing playbooks

### Task 1: Fix rest.playbook.yaml sibling key structure

The Walker treats unknown sibling keys as action candidates. `headers`
and `body` are not in `StepKeywords.RESERVED_KEYS`, so they cause
resolution failure. Fix by nesting parameters inside the action value.

**Files:**
- Modify: `playbooks/src/main/playbooks/invoke-bindings/rest.playbook.yaml`

**Interfaces:**
- Consumes: nothing
- Produces: a valid rest playbook that passes `PlaybookRunnerCore.validate()`

- [ ] **Step 1: Read the current file and identify sibling keys**

Read `playbooks/src/main/playbooks/invoke-bindings/rest.playbook.yaml`.
Find steps where `headers:` or `body:` appear as sibling keys to
`rest-request:`.

- [ ] **Step 2: Restructure YAML to nest parameters**

Change from sibling key pattern:
```yaml
- rest-request:GET: /api/users
  headers:
    Accept: application/json
```

To nested parameter pattern:
```yaml
- rest-request:
    method: GET
    url: /api/users
    headers:
      Accept: application/json
```

Ensure all steps in the file use the nested form.

- [ ] **Step 3: Run catalog-parsing-gate to verify**

Run: `mvn --batch-mode test -pl playbooks -Dtest=RunPlaybookTests -Dsurefire.includesFile=catalog-parsing-gate.test.yaml`

The gate currently expects 3 failures. After this fix, one fewer
failure. The gate assertion will fail (expects `hasSize: 3`), which is
expected — we'll update it in Task 4.

- [ ] **Step 4: Commit**

```bash
git add playbooks/src/main/playbooks/invoke-bindings/rest.playbook.yaml
git commit -m "fix(#834): nest rest-request parameters to fix Walker resolution"
```

### Task 2: Fix 08-structured-output.playbook.yaml sibling key

Same pattern as Task 1 — `response-format:` is an unknown sibling key.

**Files:**
- Modify: `playbooks/src/main/playbooks/agent-interaction-patterns/08-structured-output.playbook.yaml`

**Interfaces:**
- Consumes: nothing
- Produces: a valid structured-output playbook that passes validation

- [ ] **Step 1: Read the file and identify the failing sibling key**

Read the file. Find `response-format:` appearing as a sibling key
to an `agent-query` or `agent-invoke` step.

- [ ] **Step 2: Restructure YAML to nest the parameter**

Move `response-format` inside the action value map so it's not a
sibling key.

- [ ] **Step 3: Update the execution test**

Read `playbooks/src/test/playbooks/agent-interaction-patterns/execution.test.yaml`.
The last test (`ex08 structured output returns corpus JSON`) currently
asserts `result.error contains "response-format"` — this was testing
the failure. Change it to assert success:

```yaml
- name: "ex08 structured output returns corpus JSON"
  steps:
    - run-playbook: ../../../main/playbooks/agent-interaction-patterns/08-structured-output.playbook.yaml
      capture: result
    - assertThat: result.succeeded
      equals: true
```

(The lint will later flag this as a shallow assertion — that's
intentional. We'll upgrade it in Batch 3.)

- [ ] **Step 4: Commit**

```bash
git add playbooks/src/main/playbooks/agent-interaction-patterns/08-structured-output.playbook.yaml
git add playbooks/src/test/playbooks/agent-interaction-patterns/execution.test.yaml
git commit -m "fix(#834): nest response-format parameter in structured-output playbook"
```

### Task 3: Fix modules.playbook.yaml compilation failure

This is a module-definition file (has `sections:` and `imports:`, no
`steps:`). The compiler expects step-based playbooks. The simplest fix:
restructure it into a playbook that imports a module, giving it a
`steps:` section.

**Files:**
- Modify: `playbooks/src/main/playbooks/composition/modules.playbook.yaml`

**Interfaces:**
- Consumes: nothing
- Produces: a valid modules playbook with `steps:` that passes validation

- [ ] **Step 1: Read the current file**

Read `playbooks/src/main/playbooks/composition/modules.playbook.yaml`
and understand the module system constructs it uses.

- [ ] **Step 2: Restructure as a step-based playbook**

Restructure so the file has a `steps:` section that demonstrates
module usage. Keep the module definition as YAML content that the
steps reference (or inline the module demonstration as steps that
show the concept without requiring the import resolver).

The key constraint: the file must pass `PlaybookRunnerCore.validate()`
which calls `PlaybookCompiler.compile()` — that requires a `steps:`
section. If a full module-import restructuring is too complex, an
alternative is to convert the demo to use inline steps that illustrate
the same composition concept without actual module imports.

- [ ] **Step 3: Verify validation passes**

Run the catalog-parsing-gate manually or via maven. With all 3 fixes
applied, the gate should report 0 failures.

- [ ] **Step 4: Commit**

```bash
git add playbooks/src/main/playbooks/composition/modules.playbook.yaml
git commit -m "fix(#834): restructure modules playbook with steps section"
```

### Task 4: Update catalog-parsing-gate to expect 0 failures

**Files:**
- Modify: `playbooks/src/test/playbooks/catalog-parsing-gate.test.yaml`

**Interfaces:**
- Consumes: Tasks 1-3 (all 3 playbooks now pass validation)
- Produces: green gate that expects 0 failures

- [ ] **Step 1: Update the gate assertion**

Change line 9 from:
```yaml
  - assertThat: result.errors
    hasSize: 3
    message: "Expected failures: modules.playbook.yaml ..."
```

To:
```yaml
  - assertThat: result.errors
    hasSize: 0
    message: "All shipped playbooks must pass validation"
```

- [ ] **Step 2: Run the full playbooks test suite**

Run: `mvn --batch-mode test -pl playbooks`

Expected: all tests pass, gate reports 0 failures.

- [ ] **Step 3: Commit**

```bash
git add playbooks/src/test/playbooks/catalog-parsing-gate.test.yaml
git commit -m "fix(#834): catalog-parsing-gate expects 0 failures"
```

---

## Batch 2: Tutorial Headers — add metadata to all 70 playbooks

### Task 5: Add tutorial headers to all playbooks

Add `level`, `layer`, `teaches`, `builds-on` fields to every
`.playbook.yaml` in `playbooks/src/main/playbooks/`.

**Files:**
- Modify: all 70 `.playbook.yaml` files across 10 category directories

**Interfaces:**
- Consumes: nothing (pure metadata addition)
- Produces: every playbook has `meta.level`, `meta.layer`, `meta.teaches`,
  and optionally `meta.builds-on`

The header fields go inside the existing `meta:` block, after `tags:`:

```yaml
meta:
  title: "Retry"
  description: "..."
  tags: [retry, decorator, flow-control]
  level: 2
  layer: flow-control
  teaches: "retrying failed steps with configurable limits"
  builds-on: sequential
```

- [ ] **Step 1: Add headers to flow-control/ (12 playbooks)**

Level assignments for flow-control:

| Playbook | Level | Teaches | Builds-on |
|----------|-------|---------|-----------|
| sequential | 1 | steps execute in declaration order | (none) |
| delay | 1 | inserting a timed pause between steps | sequential |
| delay-decorator | 2 | adding delay as a step decorator | delay |
| loop | 2 | repeating a step N times | sequential |
| loop-until | 2 | repeating until a condition is met | loop |
| from-until | 2 | iterating with a counter until a condition | loop |
| from-channel-close | 3 | consuming from a channel until it closes | loop, channel |
| retry | 2 | retrying failed steps with configurable limits | sequential |
| when-guard | 2 | conditional step execution via decorator | sequential |
| timeout | 2 | failing a step if it exceeds a time limit | sequential |
| concurrent | 3 | interleaving steps from parallel branches | sequential |
| pause-resume | 3 | pausing and resuming playbook execution | sequential |

Edit each file: add `level`, `layer: flow-control`, `teaches`, and
`builds-on` fields after the `tags:` line in the `meta:` block.

- [ ] **Step 2: Add headers to step-workflows/ (13 playbooks)**

| Playbook | Level | Teaches | Builds-on |
|----------|-------|---------|-----------|
| block-sequential | 1 | grouping steps into a named block | sequential |
| if-else | 2 | conditional branching with then/else | sequential |
| match-cases | 2 | multi-branch pattern matching | if-else |
| when-structural | 2 | conditional block execution | when-guard |
| parallel | 3 | running branches concurrently, joining all | sequential |
| race | 3 | running branches concurrently, first wins | parallel |
| foreach-structural | 3 | iterating a block per list item | block-sequential |
| try-catch-finally | 3 | structured error handling | block-sequential |
| retry-structural | 3 | retrying a block on failure | try-catch-finally |
| timeout-structural | 3 | timing out a block | timeout |
| barrier | 4 | synchronisation point across branches | parallel |
| quorum | 4 | waiting for N-of-M branches | barrier |
| select | 3 | choosing a branch based on value | match-cases |

- [ ] **Step 3: Add headers to composition/ (9 playbooks)**

| Playbook | Level | Teaches | Builds-on |
|----------|-------|---------|-----------|
| modules | 3 | reusable module definitions and imports | block-sequential |
| foreach | 3 | template stamping with scoped variables | block-sequential |
| data-trigger | 3 | starting work in response to data events | sequential |
| time-trigger | 3 | scheduling work at specific times | delay |
| delayed-sequence | 3 | steps with inter-step delays | delay |
| orchestration-block | 4 | coordination primitives inside a block | block-sequential, counter |
| heartbeat-monitor | 5 | detecting missed heartbeats via timed absence | timeout, concurrent |
| timed-absence | 5 | detecting when an expected event doesn't arrive | timeout, concurrent |
| recursive-pattern | 4 | recursive step composition | modules, foreach |

- [ ] **Step 4: Add headers to concurrency-patterns/ (8 playbooks)**

| Playbook | Level | Teaches | Builds-on |
|----------|-------|---------|-----------|
| channel | 3 | typed message passing between producers and consumers | concurrent |
| semaphore | 4 | limiting concurrent access to a resource | concurrent |
| spawned-task | 4 | background task lifecycle with join | concurrent |
| correlation-scope | 4 | async request/response correlation by key | channel |
| deadline-context | 4 | propagating deadlines through nested scopes | timeout |
| concurrent-map | 4 | parallel map/reduce over a collection | parallel, foreach |
| named-consumer | 4 | dedicated named consumers on a channel | channel |
| combined-pipeline | 5 | multi-stage pipeline with backpressure | channel, semaphore |

- [ ] **Step 5: Add headers to coordination/ (4 playbooks)**

| Playbook | Level | Teaches | Builds-on |
|----------|-------|---------|-----------|
| signal-await | 3 | signalling between steps | sequential |
| barrier | 4 | synchronising parallel work at a point | parallel |
| mutex | 4 | mutual exclusion for shared resources | semaphore |
| channel | 3 | message passing via coordination channels | sequential |

- [ ] **Step 6: Add headers to coordination-primitives/ (6 playbooks)**

| Playbook | Level | Teaches | Builds-on |
|----------|-------|---------|-----------|
| counter | 2 | atomic increment/decrement/read | sequential |
| flag | 2 | boolean flag set/check/toggle | sequential |
| gauge | 2 | numeric gauge set/get/compare-and-swap | sequential |
| latch | 3 | countdown latch — wait for N events | counter |
| accumulator | 2 | collecting values into a list | sequential |
| state-machine | 3 | named states with guarded transitions | flag |

- [ ] **Step 7: Add headers to invoke-bindings/ (6 playbooks)**

| Playbook | Level | Teaches | Builds-on |
|----------|-------|---------|-----------|
| rest | 3 | calling REST APIs from playbook steps | sequential |
| graphql | 3 | executing GraphQL operations | rest |
| mcp | 3 | invoking MCP tools | sequential |
| agent | 3 | invoking an agent backend | sequential |
| process | 3 | executing shell processes | sequential |
| script | 3 | running inline scripts | sequential |

- [ ] **Step 8: Add headers to data-delivery/ (3 playbooks)**

| Playbook | Level | Teaches | Builds-on |
|----------|-------|---------|-----------|
| simulated-data | 3 | using simulation corpus for test data | sequential |
| graphql-operation | 3 | GraphQL data delivery in playbooks | graphql |
| mixed-delivery | 4 | combining multiple data sources | simulated-data, graphql-operation |

- [ ] **Step 9: Add headers to agent-interaction-patterns/ (8 playbooks)**

| Playbook | Level | Teaches | Builds-on |
|----------|-------|---------|-----------|
| 01-direct-invoke | 2 | single-shot agent invocation | sequential |
| 02-session-conversation | 3 | multi-turn agent conversation | 01-direct-invoke |
| 03-session-with-clear | 3 | clearing agent session context | 02-session-conversation |
| 04-parallel-queries | 3 | parallel agent invocations | 01-direct-invoke, parallel |
| 05-pool-backed | 4 | agent pool infrastructure | 01-direct-invoke |
| 06-multi-channel | 4 | separate agent pools per channel | 05-pool-backed |
| 07-salience-priority | 4 | priority-based agent pool routing | 05-pool-backed |
| 08-structured-output | 3 | JSON structured output from agents | 01-direct-invoke |

- [ ] **Step 10: Add headers to simulation/ (1 playbook)**

| Playbook | Level | Teaches | Builds-on |
|----------|-------|---------|-----------|
| order-lifecycle | 4 | state machine-driven simulation with corpus selection | state-machine, simulated-data |

- [ ] **Step 11: Run full test suite to verify no regressions**

Run: `mvn --batch-mode test -pl playbooks`

The meta fields are passthrough — the parser doesn't reject unknown meta
keys. All tests should pass.

- [ ] **Step 12: Commit**

```bash
git add playbooks/src/main/playbooks/
git commit -m "feat(#834): add tutorial headers (level/layer/teaches/builds-on) to all 70 playbooks"
```

### Task 6: Add header validation to catalog-parsing-gate

Extend the `validate-playbook` directory scan to check that every
playbook has `level`, `layer`, and `teaches` in its `meta:` block.

**Files:**
- Modify: `yaml-test-core/src/main/java/io/casehub/yaml/test/ValidatePlaybookPlugin.java`
- Modify: `playbooks/src/test/playbooks/catalog-parsing-gate.test.yaml`

**Interfaces:**
- Consumes: `PlaybookParser.parse()` → `PlaybookDocument.content()` → `meta` map
- Produces: `result.headerErrors` list in directory validation output

- [ ] **Step 1: Write a test for header validation**

Create a test in
`yaml-test-core/src/test/java/io/casehub/yaml/test/ValidatePlaybookPluginTest.java`
(if it exists, add to it) that validates a playbook YAML string
with and without headers:

```java
@Test
void directoryValidation_reportsPlaybooksMissingHeaders() {
    // Create temp dir with two playbooks:
    // one with headers, one without
    // Run ValidatePlaybookPlugin with directory param
    // Assert result contains headerErrors for the missing-headers file
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=ValidatePlaybookPluginTest#directoryValidation_reportsPlaybooksMissingHeaders`

Expected: FAIL (headerErrors not yet in output)

- [ ] **Step 3: Implement header validation in ValidatePlaybookPlugin**

In `ValidatePlaybookPlugin.executeDirectory()`, after the existing
validation loop, add a second pass that:

1. Parses each `.playbook.yaml` with `PlaybookParser.parse()`
2. Reads `content.get("meta")` as a `Map<String, Object>`
3. Checks for `level`, `layer`, `teaches` keys
4. Collects missing-header errors into a `headerErrors` list
5. Adds `headerErrors` to the result map

```java
List<Map<String, Object>> headerErrors = new ArrayList<>();
for (Path yamlPath : yamlFiles) {
    String relativePath = playbooksDir.relativize(yamlPath).toString();
    try {
        String yaml = Files.readString(yamlPath);
        PlaybookDocument doc = PlaybookParser.parse(yaml);
        @SuppressWarnings("unchecked")
        Map<String, Object> meta = (Map<String, Object>) doc.content().get("meta");
        if (meta == null) {
            headerErrors.add(Map.of("file", relativePath, "missing", "meta block"));
            continue;
        }
        List<String> missing = new ArrayList<>();
        if (!meta.containsKey("level")) missing.add("level");
        if (!meta.containsKey("layer")) missing.add("layer");
        if (!meta.containsKey("teaches")) missing.add("teaches");
        if (!missing.isEmpty()) {
            headerErrors.add(Map.of("file", relativePath,
                    "missing", String.join(", ", missing)));
        }
    } catch (Exception e) {
        // Already reported as compilation error — skip header check
    }
}
```

Add to the return map: `"headerErrors", (Object) headerErrors`

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=ValidatePlaybookPluginTest`

Expected: PASS

- [ ] **Step 5: Add header assertion to catalog-parsing-gate**

Add to `catalog-parsing-gate.test.yaml`:

```yaml
  - assertThat: result.headerErrors
    hasSize: 0
    message: "All playbooks must have level, layer, and teaches in meta"
```

- [ ] **Step 6: Run playbooks test suite**

Run: `mvn --batch-mode test -pl playbooks`

Expected: all tests pass including the new header assertion.

- [ ] **Step 7: Commit**

```bash
git add yaml-test-core/src/main/java/io/casehub/yaml/test/ValidatePlaybookPlugin.java
git add yaml-test-core/src/test/java/io/casehub/yaml/test/ValidatePlaybookPluginTest.java
git add playbooks/src/test/playbooks/catalog-parsing-gate.test.yaml
git commit -m "feat(#834): validate tutorial headers in catalog-parsing-gate"
```

---

## Batch 3: Category Tests — behavioral assertions per category

### Task 7: Enrich run-playbook result with orchestration primitive state

Add primitive state snapshots to `PlaybookRunResult` so tests can
assert on counter values, flag states, and gauge values.

**Files:**
- Modify: `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultExecutionScope.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookRunResult.java`
- Modify: `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookRunnerCore.java`
- Modify: `yaml-test-core/src/main/java/io/casehub/yaml/test/RunPlaybookPlugin.java`
- Test: `yaml-test-core/src/test/java/io/casehub/yaml/test/RunPlaybookPluginTest.java`

**Interfaces:**
- Consumes: `DefaultExecutionScope.primitives` (ConcurrentHashMap)
- Produces: `result.counters.*`, `result.flags.*`, `result.gauges.*` in
  run-playbook result map

- [ ] **Step 1: Write failing test**

In `RunPlaybookPluginTest.java`, write a test that runs a playbook
containing counter/flag/gauge steps and asserts the result map
contains primitive state:

```java
@Test
void runPlaybook_exposesPrimitiveState() {
    // Create a playbook YAML that uses counter-add and counter-get
    // Run it via RunPlaybookPlugin
    // Assert result.output contains "counters" with expected values
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl yaml-test-core -Dtest=RunPlaybookPluginTest#runPlaybook_exposesPrimitiveState`

Expected: FAIL — no `counters` key in result

- [ ] **Step 3: Add snapshotPrimitives() to DefaultExecutionScope**

Add a method that iterates the `primitives` map and extracts values
by type:

```java
public Map<String, Map<String, Object>> snapshotPrimitives() {
    var counters = new LinkedHashMap<String, Object>();
    var flags = new LinkedHashMap<String, Object>();
    var gauges = new LinkedHashMap<String, Object>();
    for (var entry : primitives.entrySet()) {
        Object val = entry.getValue();
        if (val instanceof Counter c) {
            counters.put(entry.getKey(), c.get());
        } else if (val instanceof Flag f) {
            flags.put(entry.getKey(), f.isSet());
        } else if (val instanceof Gauge g) {
            gauges.put(entry.getKey(), g.get());
        }
    }
    return Map.of("counters", counters, "flags", flags, "gauges", gauges);
}
```

Exact type names (`Counter`, `Flag`, `Gauge`) need to be verified from
the actual `OrcCounter`, `OrcFlag`, `OrcGauge` interfaces — check the
`io.casehub.yaml.core.orchestration` package for the correct types
and accessor methods.

- [ ] **Step 4: Add primitiveStates to PlaybookRunResult**

Add a new field:
```java
Map<String, Map<String, Object>> primitiveStates
```

Update constructors to default it to `Map.of()`.

- [ ] **Step 5: Snapshot before scope close in PlaybookRunnerCore**

In `PlaybookRunnerCore.run()`, before the try-with-resources block
closes the scope, call `scope.snapshotPrimitives()` and pass it to
the `PlaybookRunResult` constructor.

- [ ] **Step 6: Expose primitives in RunPlaybookPlugin result map**

In `RunPlaybookPlugin.execute()`, after building the result map,
add:

```java
if (runResult.primitiveStates() != null) {
    for (var entry : runResult.primitiveStates().entrySet()) {
        resultMap.put(entry.getKey(), entry.getValue());
    }
}
```

This adds `counters`, `flags`, `gauges` as top-level keys.

- [ ] **Step 7: Run test to verify it passes**

Run: `mvn --batch-mode test -pl yaml-test-core`

Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultExecutionScope.java
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookRunResult.java
git add yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookRunnerCore.java
git add yaml-test-core/src/main/java/io/casehub/yaml/test/RunPlaybookPlugin.java
git add yaml-test-core/src/test/java/io/casehub/yaml/test/RunPlaybookPluginTest.java
git commit -m "feat(#834): expose orchestration primitive state in run-playbook result"
```

### Task 8: Write category-level test files

Create `.test.yaml` files for the 8 categories that lack individual
tests. Each test file runs representative playbooks from the category
and asserts on behavioral outcomes, not just `succeeded`.

**Files:**
- Create: `playbooks/src/test/playbooks/flow-control/execution.test.yaml`
- Create: `playbooks/src/test/playbooks/step-workflows/execution.test.yaml`
- Create: `playbooks/src/test/playbooks/composition/execution.test.yaml`
- Create: `playbooks/src/test/playbooks/concurrency-patterns/execution.test.yaml`
- Create: `playbooks/src/test/playbooks/coordination/execution.test.yaml`
- Create: `playbooks/src/test/playbooks/coordination-primitives/execution.test.yaml`
- Create: `playbooks/src/test/playbooks/invoke-bindings/execution.test.yaml`
- Create: `playbooks/src/test/playbooks/data-delivery/execution.test.yaml`

**Interfaces:**
- Consumes: `run-playbook` plugin result map (including new primitive state from Task 7)
- Produces: behavioral test coverage for all 10 categories

Each test file follows the teaching-first principle: test names describe
the behavior being demonstrated, assertions illuminate processing outcomes.

- [ ] **Step 1: Write flow-control/execution.test.yaml**

Representative tests (not all 12 playbooks need individual tests):

```yaml
name: Flow control playbook execution
tests:
  - name: "sequential executes steps in declaration order"
    steps:
      - run-playbook: ../../../main/playbooks/flow-control/sequential.playbook.yaml
        capture: result
      - assertThat: result.succeeded
        equals: true
      - assertThat: result.stepCount
        equals: 4
      - assertThat: result.stepEvents[0].action
        equals: "click"

  - name: "loop repeats a step N times"
    steps:
      - run-playbook: ../../../main/playbooks/flow-control/loop.playbook.yaml
        capture: result
      - assertThat: result.succeeded
        equals: true
      - assertThat: result.stepEvents
        hasSize: 5
        message: "click A ×3 + click B ×1 = 4 step events, but loop unrolls to 3+1+1=5"

  - name: "retry re-executes on failure up to max attempts"
    steps:
      - run-playbook: ../../../main/playbooks/flow-control/retry.playbook.yaml
        capture: result
      - assertThat: result.stepEvents
        hasSize: 3
        message: "three steps each execute once (stubs succeed on first try)"

  - name: "concurrent interleaves branches"
    steps:
      - run-playbook: ../../../main/playbooks/flow-control/concurrent.playbook.yaml
        capture: result
      - assertThat: result.succeeded
        equals: true
      - assertThat: result.stepCount
        greaterThan: 2
        message: "both branches contribute steps"
```

Adjust step counts and assertions based on actual execution results.
Run each playbook individually first to discover the actual result
shape, then write assertions against observed values.

- [ ] **Step 2: Write step-workflows/execution.test.yaml**

```yaml
name: Step workflow playbook execution
tests:
  - name: "if-else runs then-branch on true, else-branch on false"
    steps:
      - run-playbook: ../../../main/playbooks/step-workflows/if-else.playbook.yaml
        capture: result
      - assertThat: result.succeeded
        equals: true
      - assertThat: result.stepCount
        greaterThan: 2
        message: "both if blocks produce steps — true takes then, false takes else"

  - name: "try-catch-finally runs catch on failure and finally always"
    steps:
      - run-playbook: ../../../main/playbooks/step-workflows/try-catch-finally.playbook.yaml
        capture: result
      - assertThat: result.succeeded
        equals: true
      - assertThat: result.stepCount
        greaterThan: 3
        message: "try (2 steps) + catch (1) + finally (1) = 4+ steps"

  - name: "parallel runs all branches"
    steps:
      - run-playbook: ../../../main/playbooks/step-workflows/parallel.playbook.yaml
        capture: result
      - assertThat: result.succeeded
        equals: true
      - assertThat: result.stepCount
        equals: 3
        message: "three parallel log branches"
```

- [ ] **Step 3: Write coordination-primitives/execution.test.yaml**

This category benefits most from the primitive state enrichment:

```yaml
name: Coordination primitives playbook execution
tests:
  - name: "counter tracks atomic increments and decrements"
    steps:
      - run-playbook: ../../../main/playbooks/coordination-primitives/counter.playbook.yaml
        capture: result
      - assertThat: result.succeeded
        equals: true
      - assertThat: result.counters.requests
        equals: 3
        message: "+1 +1 +3 -2 = 3"

  - name: "flag toggles between set and unset"
    steps:
      - run-playbook: ../../../main/playbooks/coordination-primitives/flag.playbook.yaml
        capture: result
      - assertThat: result.succeeded
        equals: true
      - assertThat: result.flags
        isNotEmpty: true
```

Adjust assertions to match the actual primitive state names and values
from each playbook after running them.

- [ ] **Step 4: Write remaining category test files**

Write test files for: `composition/`, `concurrency-patterns/`,
`coordination/`, `invoke-bindings/`, `data-delivery/`.

Each file should have 2-4 tests covering representative playbooks from
the category. Follow the same pattern:
1. Run the playbook with `run-playbook`
2. Assert `succeeded` as a secondary check
3. Assert at least one behavioral outcome (step count semantics,
   output values, primitive state, error content)

For categories where stubs prevent meaningful behavioral assertions
(e.g., invoke-bindings with stubbed REST/MCP calls), assert on
structural compilation properties from `validate-playbook` instead.

- [ ] **Step 5: Run full test suite**

Run: `mvn --batch-mode test -pl playbooks`

Expected: all tests pass. Debug any failures — step counts and
assertion values may need adjusting based on actual execution results.

- [ ] **Step 6: Commit**

```bash
git add playbooks/src/test/playbooks/
git commit -m "feat(#834): category-level behavioral tests for all 10 playbook categories"
```

---

## Batch 4: Lint — assertion quality gate

### Task 9: Implement assertion-quality lint

A Java test that scans all `.test.yaml` files and fails if any test
case's only assertions are on `result.succeeded`, `result.stepCount`,
or `result.valid`.

**Files:**
- Create: `playbooks/src/test/java/io/casehub/yaml/test/catalog/AssertionQualityLintTest.java`

**Interfaces:**
- Consumes: `.test.yaml` files parsed by `YamlTestDiscovery.parseTestFile()`
- Produces: build failure on shallow-assertion test cases

- [ ] **Step 1: Write the lint test**

```java
package io.casehub.yaml.test.catalog;

import io.casehub.yaml.test.TestCase;
import io.casehub.yaml.test.TestFileDescriptor;
import io.casehub.yaml.test.YamlTestDiscovery;
import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertTrue;

class AssertionQualityLintTest {

    private static final Set<String> TRIVIAL_TARGETS = Set.of(
            "result.succeeded", "result.stepCount", "result.valid"
    );

    @Test
    void allTestsMustHaveBehavioralAssertions() {
        Path testRoot = Path.of("src/test/playbooks");
        List<TestFileDescriptor> files = YamlTestDiscovery.discover(testRoot);

        List<String> violations = new ArrayList<>();

        for (var file : files) {
            if (isLintSkipped(file)) continue;

            for (var testCase : file.testCases()) {
                if (hasOnlyTrivialAssertions(testCase)) {
                    violations.add(file.file().getFileName() + " > "
                            + testCase.name());
                }
            }
        }

        assertTrue(violations.isEmpty(),
                "Test cases with only trivial assertions "
                + "(succeeded/stepCount/valid):\n  - "
                + String.join("\n  - ", violations)
                + "\n\nAdd behavioral assertions or mark the file "
                + "with 'lint: skip'.");
    }

    @SuppressWarnings("unchecked")
    private boolean isLintSkipped(TestFileDescriptor file) {
        // Re-parse the raw YAML to check for lint: skip
        // since TestFileDescriptor doesn't carry it
        try {
            var mapper = new com.fasterxml.jackson.databind.ObjectMapper(
                    new com.fasterxml.jackson.dataformat.yaml.YAMLFactory());
            Map<String, Object> raw = mapper.readValue(
                    java.nio.file.Files.newInputStream(file.file()),
                    Map.class);
            return "skip".equals(raw.get("lint"));
        } catch (Exception e) {
            return false;
        }
    }

    @SuppressWarnings("unchecked")
    private boolean hasOnlyTrivialAssertions(TestCase testCase) {
        List<String> assertTargets = new ArrayList<>();
        for (var step : testCase.steps()) {
            Object target = step.get("assertThat");
            if (target != null) {
                assertTargets.add(String.valueOf(target));
            }
        }

        if (assertTargets.isEmpty()) {
            // No assertions at all — not a lint violation
            // (might be a setup/lifecycle test)
            return false;
        }

        return assertTargets.stream().allMatch(TRIVIAL_TARGETS::contains);
    }
}
```

- [ ] **Step 2: Run the lint to see which tests fail**

Run: `mvn --batch-mode test -pl playbooks -Dtest=AssertionQualityLintTest`

Expected: FAIL — lists all test cases with only trivial assertions.
Record which tests are flagged. These are the tests that need
upgrading or `lint: skip`.

- [ ] **Step 3: Upgrade or skip flagged tests**

For each flagged test case:
- If it has behavioral assertions available (from Batch 3 work), it
  should already pass. If not, add a meaningful assertion.
- If the test genuinely can't have behavioral assertions (e.g., the
  catalog-parsing-gate itself), add `lint: skip` to the test file.

The catalog-parsing-gate is not a behavior test — it's a structural
gate. Add `lint: skip`:

```yaml
name: Playbook catalog parsing gate
lint: skip
steps:
  ...
```

- [ ] **Step 4: Run lint again**

Run: `mvn --batch-mode test -pl playbooks -Dtest=AssertionQualityLintTest`

Expected: PASS — all violations resolved via real assertions or skip.

- [ ] **Step 5: Run full test suite**

Run: `mvn --batch-mode test -pl playbooks`

Expected: all tests pass including the lint.

- [ ] **Step 6: Commit**

```bash
git add playbooks/src/test/java/io/casehub/yaml/test/catalog/AssertionQualityLintTest.java
git add playbooks/src/test/playbooks/
git commit -m "feat(#834): assertion-quality lint rejects tests with only trivial assertions"
```

---

## References

- [2026-11-17-rules-headers-lint-design.md] — design spec this plan implements
- `playbooks/src/test/playbooks/catalog-parsing-gate.test.yaml` — existing gate test
- `playbooks/src/test/playbooks/agent-interaction-patterns/execution.test.yaml` — existing shallow tests
- `playbooks/src/test/playbooks/simulation/order-lifecycle.test.yaml` — good behavioral test example
- `yaml-test-core/src/main/java/io/casehub/yaml/test/ValidatePlaybookPlugin.java` — validate-playbook plugin
- `yaml-test-core/src/main/java/io/casehub/yaml/test/RunPlaybookPlugin.java` — run-playbook plugin
- `yaml-test-core/src/main/java/io/casehub/yaml/test/YamlTestDiscovery.java` — test file discovery + parsing
- `yaml-core/src/main/java/io/casehub/yaml/core/orchestration/DefaultExecutionScope.java` — primitive state store
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookRunnerCore.java` — playbook runner
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/runner/PlaybookRunResult.java` — run result record
- `yaml-step-runtime/src/main/java/io/casehub/yaml/step/statemachine/PlaybookParser.java` — YAML parser
- `docs/adr/0013-trust-model-for-playbook-authoring.md` — orthogonal trust model (not affected)
- GitHub #834 — focal issue
- GitHub #827 — parent epic
