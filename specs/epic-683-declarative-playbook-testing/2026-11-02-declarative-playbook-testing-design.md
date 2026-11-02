# Declarative Playbook Testing and Simulation Alignment

**Epic:** #683
**Date:** 2026-11-02
**Status:** Draft

## Vision

Playbook testing should be as declarative as the playbooks themselves. A
`.test.yaml` file IS a playbook — it extends the standard playbook format
with a `simulate:` top-level block and uses assert steps to verify
outcomes. Tests double as tutorials: each file is a self-contained,
readable walkthrough that also happens to be executable.

Three workstreams converge:

1. **Simulation alignment** — temporal event sequences become playbook
   steps; corpus/strategy configuration stays as-is
2. **Declarative testing infrastructure** — assertThat matchers,
   run-playbook step, emit-event step, JUnit Platform TestEngine + CLI
3. **Migration** — rewrite Java integration tests as `.test.yaml` files,
   helpdesk as first 100% YAML app + 100% YAML test target

## Core Model

A `.test.yaml` file is a regular playbook with one addition: a
`simulate:` top-level block that configures which SPI calls return
simulated responses. The test runner:

1. Discovers `*.test.yaml` by convention
2. Parses as `PlaybookDocument` with `simulate:` section
3. Creates an `EventCapture` for the test scope
4. If `simulate:` is present, pushes a `SimulationOverlay` onto
   `SimulationRuntime`
5. Resolves steps via Walker + PluginRegistry (the same step
   resolution pipeline used by the interactive runtime)
6. Executes via CatalogStepRunner + StructuralStepEvaluator
7. If `simulate:` was present, pops the overlay and runs corpus
   verification
8. Reports pass/fail based on assert step outcomes

### Execution path

Tests use the **Walker path** exclusively — the same Walker +
CatalogStepRunner + StructuralStepEvaluator pipeline that handles
interactive playbook execution. The PlaybookCompiler → Serverless
Workflow path is for production deployment and is not involved in
test execution.

This means `@Plugin` steps (assert, assertThat, run-playbook,
emit-event) resolve through the PluginRegistry, and structural steps
(parallel, try/catch, race, etc.) resolve through the Walker's
structural step handling. Both paths are already unified in the Walker.

The `run-playbook` step also uses the Walker path for the target
playbook — it parses the target file, resolves via Walker, and
executes within the current simulation context.

Two test styles from one format:

- **Tutorial style** — the test IS the walkthrough with inline steps
  and assertions
- **Validation style** — the test runs an existing playbook via
  `run-playbook` and asserts on captured outputs

## YAML Format

### Level 1 — Single agent invocation

```yaml
name: Basic agent invocation

simulate:
  agent:
    - prompt: "What's my risk profile?"
      response: "Moderate risk: 60% equities, 30% bonds, 10% cash."

steps:
  - agent-invoke:
      prompt: "What's my risk profile?"
    capture: result
  - assertThat: ${result.text}
    contains: 'equities'
```

### Level 2 — Session with multiple turns

```yaml
name: Session preserves conversation context

simulate:
  agent:
    - prompt: "What's my risk profile?"
      response: "Moderate risk: 60% equities."
    - prompt: "How should I rebalance?"
      response: "Shift 10% equities to bonds."

steps:
  - agent-session-open:
      pool: financial-advisor
    capture: session
  - agent-query:
      session: ${session}
      prompt: "What's my risk profile?"
    capture: risk
  - assertThat: ${risk}
    contains: 'equities'
  - agent-query:
      session: ${session}
      prompt: "How should I rebalance?"
    capture: rebalance
  - assertThat: ${rebalance}
    contains: 'bonds'
  - agent-session-close:
      session: ${session}
```

### Level 3 — Validation of an existing playbook

```yaml
name: Verify session conversation example

simulate:
  agent:
    corpus-file: corpora/financial-qa.yaml

steps:
  - run-playbook: examples/02-session-conversation.yaml
    capture: results
  - assert:
      expression: ${results.succeeded}
  - assertThat: ${results.output.risk_assessment}
    contains: 'equities'
```

### Level 4 — Temporal events (replacing TemporalSimulationDriver)

```yaml
name: Capacity pressure triggers redistribution

steps:
  - emit-event: capacity.pressure
    data:
      actorId: agent-001
      pressure: 0.92
  - delay: 500ms
  - emit-event: capacity.pressure
    data:
      actorId: agent-001
      pressure: 0.96
  - delay: 200ms
  - assertThat: ${events.last('redistribution.decision')}
    not-null: true
  - assertThat: ${events.last('redistribution.decision').data.reason}
    contains: 'threshold'
```

### Level 5 — Mixed simulation with external corpus

```yaml
name: Multi-turn agent with tool use
description: >
  Agent uses REST tools across multiple turns,
  maintaining context between invocations.

simulate:
  agent:
    strategy: nearest-match
    corpus-file: corpora/tool-use-scenarios.yaml
  portfolio-api.getPortfolio:
    strategy: key
    key-extractor: "field:url"
    corpus:
      - key: "/api/portfolio"
        output: { status: 200, body: { total: 150000, equities: 90000 } }

steps:
  - run-playbook: examples/05-tool-use-patterns.yaml
    capture: results
  - assert:
      expression: ${results.succeeded}
  - assertThat: ${results.stepCount}
    greaterThanOrEqual: 4
  - assertThat: ${results.output.portfolio_summary}
    contains: 'equities'
```

## Simulate Block

### Alias resolution

The simulate block uses domain aliases that resolve to qualified SPI
method names with sensible defaults:

| Alias | Resolves to | Default strategy | Default key-extractor |
|-------|-------------|------------------|-----------------------|
| `agent` | `agent-provider.invoke` (`AgentProviderQN.INVOKE`) | `key` | `field:user-prompt` |

REST clients do not have a generic alias — each `@RegisterRestClient`
interface generates its own qualified name via
`RestClientSimulationProcessor` (based on `configKey` or kebab-case of
the class name). Use the full qualified name syntax:

```yaml
simulate:
  portfolio-api.getPortfolio:
    strategy: key
    key-extractor: "field:url"
    corpus:
      - key: "/api/portfolio"
        output: { status: 200, body: { total: 150000 } }
```

Full simulation.yaml method syntax is available for advanced cases:

```yaml
simulate:
  agent-provider.invoke:
    strategy: nearest-match
    key-extractor: "field:user-prompt"
    scorer: "jaccard"
    corpus:
      - key: "risk profile"
        output: "Moderate risk: 60% equities."
```

### Corpus entry shorthands

Domain aliases also normalise corpus field names:

| Alias | Shorthand fields | Canonical fields |
|-------|-----------------|------------------|
| `agent` | `prompt` / `response` | `key` / `output` |

### Corpus sources

Three alternatives (YAML maps cannot have duplicate keys, so only one
`agent:` block per `simulate:` — pick the form that fits):

**Inline entries** — self-contained, good for tutorials:
```yaml
simulate:
  agent:
    - prompt: "question"
      response: "answer"
```

**External file** — shared across tests:
```yaml
simulate:
  agent:
    corpus-file: corpora/financial-qa.yaml
```

**Mixed** — external base + test-specific overrides (the combination
pattern):
```yaml
simulate:
  agent:
    corpus-file: corpora/financial-qa.yaml
    corpus:
      - prompt: "extra test case"
        response: "Test-specific response."
```

### Overlay lifecycle

The simulate block maps directly to `SimulationRuntime`'s overlay stack:

1. Parser resolves aliases → canonical method names
2. Normalises shorthand fields → canonical fields
3. Builds `SimulationOverlay` via `YamlSimulationConfig` parser
4. `SimulationRuntime.pushOverlay(overlay)` before step execution
5. `SimulationRuntime.popOverlay()` after execution (in finally block)

No new simulation infrastructure — the simulate block reuses the
existing overlay stack from feat-294 (D43-47). The testing framework
itself (modules, step types, TestEngine) is new.

## Step Types

### agent-invoke (new step type — single-call convenience)

Wraps agent-session-open → agent-query → agent-session-close for
single-turn interactions. Registered in `PlaybookCompiler` with its
own `StepCompiler`, and in the `PluginRegistry` as a `@Plugin` for
Walker-path execution.

```yaml
- agent-invoke:
    prompt: "What's my risk profile?"
  capture: result
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `prompt` | String | yes | The user prompt to send |
| `pool` | String | no | Agent pool name (defaults to system default) |

The capture object contains: `text` (response text), `tokens`
(token count), `duration` (ms). This step type does not exist in
the codebase today — it is new for this epic.

### assertThat (new @Plugin — primary test assertion)

Subject-first behavioural assertions. `assertThat:` takes the subject
as its scalar value, matchers as sibling YAML keys.

```yaml
# Single matcher
- assertThat: ${response}
  contains: 'equities'

# Multiple matchers on same subject
- assertThat: ${response}
  contains: 'equities'
  startsWith: 'Moderate'

# With custom message
- assertThat: ${response}
  contains: 'equities'
  message: "Risk assessment should mention equities"
```

Available matchers:

| Matcher | Example | Description |
|---------|---------|-------------|
| `contains` | `contains: 'foo'` | String/collection contains |
| `equals` | `equals: 'foo'` | Equality check |
| `matches` | `matches: '\\d+'` | Regex match |
| `hasSize` | `hasSize: 3` | Collection size |
| `startsWith` | `startsWith: 'prefix'` | String prefix |
| `endsWith` | `endsWith: 'suffix'` | String suffix |
| `greaterThan` | `greaterThan: 5` | Numeric comparison |
| `greaterThanOrEqual` | `greaterThanOrEqual: 4` | Numeric comparison |
| `lessThan` | `lessThan: 10` | Numeric comparison |
| `not-null` | `not-null: true` | Non-null check |
| `not-empty` | `not-empty: true` | Non-empty check |
| `empty` | `empty: true` | Empty check |

When multiple matchers are present, ALL must pass. Each failed matcher
is reported — not just the first.

**Walker integration:** `assertThat` is a sibling-absorbing plugin —
the Walker, after matching `assertThat:` as the action key, collects
all remaining non-reserved, non-structural keys as plugin parameters
rather than throwing "unknown key". The matchers (`contains`,
`equals`, etc.) become entries in the plugin's parameter map alongside
a `_subject` entry holding the scalar value. This is a general Walker
enhancement: plugins can opt into sibling absorption via
`@Plugin(absorbSiblings = true)`. The `emit-event` plugin uses the
same mechanism for its `data:` sibling key.

**Subject resolution:** The `assertThat` plugin resolves its subject
using two-phase resolution:

1. **VariableResolver phase** — standard `${...}` resolution. Works
   for simple captured variables: `${result.text}`,
   `${results.succeeded}`.
2. **Expression engine phase** — if the subject still contains
   unresolved `${...}` after VariableResolver (because the prefix
   was deferred), the plugin strips the `${}` wrapper and evaluates
   the inner expression via the expression engine (MVEL3). Works for
   method-call expressions: `events.last('redistribution.decision')`.

This two-phase approach is localised to the `assertThat` plugin —
it does not change `VariableResolver`, `ObjectVariableSource`, or
`FieldDriller`. The `assertThat` plugin already requires access to
`ExpressionEngineRegistry` (same dependency as `assert`).

Assertion failures produce structured error messages with subject
and expectation separated:

```
AssertionFailed: step 4 of "Verify session example"
  Subject: ${results.output.risk_assessment}
  Actual: "The portfolio is balanced."
  Failed:
    contains: 'equities' — actual value does not contain 'equities'
    startsWith: 'Moderate' — actual value starts with 'The'
```

### assert (existing @Plugin — boolean escape hatch)

Retained for simple boolean truth checks where a subject + matcher
would be ceremony. Uses the existing `AssertPlugin` with the
configured expression engine (MVEL3 or JQ).

```yaml
# Expression with message
- assert:
    expression: ${results.stepCount} > 0 && ${results.succeeded}
    message: "Playbook must succeed with at least one step"

# Simple check (expression only)
- assert:
    expression: ${results.succeeded}

# Event query in boolean expression
- assert:
    expression: ${events.count('capacity.pressure')} >= 2
```

**Expression pre-processing:** After VariableResolver processes the
params, the expression may contain a mix of resolved values and
unresolved `${...}` references (deferred prefixes like `events`).
The `assert:` plugin pre-processes the expression before MVEL
compilation:

1. Strip remaining `${}` wrappers — turning
   `${events.count('capacity.pressure')} >= 2` into
   `events.count('capacity.pressure') >= 2`
2. Evaluate via MVEL with **test-scoped context variables** (including
   `events` → EventCapture) instead of the current
   `compiled.eval(Map.of())`

This is the same two-phase pattern as `assertThat`'s subject
resolution, applied to the expression string. Both plugins share
the same MVEL context binding.

`assert:` evaluates a boolean expression via the expression engine.
`assertThat:` applies matchers to a subject as sibling YAML keys.
Two step names, two purposes — and two different mechanisms (expression
engine vs plugin parameter matchers). Both support event queries via
the deferred-prefix + MVEL fallback.

### run-playbook (new @Plugin)

Executes another playbook within the current simulation context:

```yaml
# Short form — file path as scalar
- run-playbook: examples/02-session-conversation.yaml
  capture: results

# Full form — with variables
- run-playbook:
    file: examples/02-session-conversation.yaml
    vars:
      portfolio: conservative
    capture: results
```

The capture object contains:

| Field | Type | Description |
|-------|------|-------------|
| `succeeded` | boolean | All steps completed without error |
| `output` | Map | Playbook output variables |
| `stepCount` | int | Total steps executed |
| `duration` | long | Execution time in ms |
| `stepEvents` | List | Step execution events (distinct from `${events}` CloudEvent capture) |
| `error` | String | Error message if failed (null if succeeded) |

Scalar-or-object polymorphism via `ShorthandModule`:
- String value → file path (shorthand)
- Map value → full form with file, vars, capture

**Path resolution:** Relative paths are resolved against the **test
resource root** (`src/test/resources/`), which is the same base used
by `YamlTestDiscovery` for test file scanning. This means
`run-playbook: examples/02-session-conversation.yaml` resolves to
`src/test/resources/examples/02-session-conversation.yaml` regardless
of the test file's own location in the directory tree. Absolute paths
are used as-is.

### emit-event (new @Plugin)

Fires a CloudEvent into the system, replacing
`TemporalSimulationDriver`:

```yaml
# Short form — event type as scalar, data as sibling
- emit-event: capacity.pressure
  data:
    actorId: agent-001
    pressure: 0.92

# Full form
- emit-event:
    type: capacity.pressure
    source: /test/capacity
    data:
      actorId: agent-001
      pressure: 0.92
```

Uses `CloudEventFixtureBuilder.fromMap()` for construction, fires via
CDI event bus (or directly to EventCapture in CLI mode).
Scalar-or-object polymorphism: string value → event type, map value →
full CloudEvent spec.

### verify-simulation (new @Plugin — simulation verification)

Explicit assertions on simulation invocation journal, exposing
`SimulationVerifier`'s capabilities in YAML:

```yaml
# Verify specific method was called
- verify-simulation:
    method: agent-provider.invoke
    called: 2

# Verify call ordering
- verify-simulation:
    inOrder:
      - agent-provider.invoke
      - portfolio-api.getPortfolio

# Verify all corpus entries were consumed
- verify-simulation:
    exhaustive: true
```

| Field | Type | Description |
|-------|------|-------------|
| `method` | String | Qualified SPI method name |
| `called` | int | Expected invocation count |
| `calledAtLeast` | int | Minimum invocation count |
| `calledAtMost` | int | Maximum invocation count |
| `neverCalled` | boolean | Assert method was never called |
| `inOrder` | List | Assert methods were called in this order |
| `exhaustive` | boolean | All corpus entries must have been matched (scoped — see below) |

Delegates to `SimulationVerifier.on(overlay)` for the active
overlay's `InvocationJournal`.

**Exhaustive scope:** `exhaustive: true` checks ALL methods
configured in the overlay's corpus — not just those that were
invoked. If the overlay configures both agent and REST simulation
but the test only exercises the agent path, `exhaustive: true` fails
because REST corpus entries were not consumed. To verify exhaustive
consumption for a single method, combine with `method:`:

```yaml
# Exhaustive for one method only
- verify-simulation:
    method: agent-provider.invoke
    exhaustive: true

# Exhaustive for ALL methods in overlay (strict)
- verify-simulation:
    exhaustive: true
```

**Automatic corpus verification:** When a test completes and a
`simulate:` block was active, the test runner reports unmatched
corpus entries in the error output (as shown in the error reporting
section). This is diagnostic — not a hard failure — unless the test
includes an explicit `verify-simulation: { exhaustive: true }` step.

## Event Capture

Tests need to assert on events fired during playbook execution.

`EventCapture` in `yaml-test-core` is a **POJO collector** — a simple
list that accumulates `CloudEvent` objects. It has no CDI dependency:

- `addEvent(CloudEvent)` — push an event
- `ofType(String)` → `List<CapturedEvent>` — filter by event type
- `last(String)` → `CapturedEvent` — last event of type
- `count(String)` → int — count of events of type

Query methods return `CapturedEvent` wrappers (not raw `CloudEvent`):

```java
public record CapturedEvent(CloudEvent event, Map<String, Object> data) {
    public String type()   { return event.getType(); }
    public String source() { return event.getSource().toString(); }
    // data() returns the CloudEvent data payload parsed as a Map,
    // enabling dot-path access via MVEL: .data.reason, .data.actorId
}
```

The `data()` → `Map<String, Object>` accessor is essential: raw
`CloudEvent.getData()` returns `CloudEventData`, which MVEL cannot
traverse as properties. The `CapturedEvent` wrapper parses the data
payload into a Map at capture time.

**Lifecycle:** EventCapture is scoped to the **test execution**, not
to the simulation overlay. The test runner creates a fresh
`EventCapture` at the start of each test and discards it at the end.
This means `${events}` is available in ALL tests — including Level 4
(temporal events) which has no `simulate:` block.

**Event sources:**
- `emit-event` plugin steps push events directly to the EventCapture
- In CDI context (JUnit/Quarkus): `TestEventCapture
  @ApplicationScoped` observes CDI `CloudEvent` and forwards to
  EventCapture — this captures events fired by application code, not
  just test steps
- In CLI context (no CDI): only `emit-event` step events are captured

### Event query resolution

Event queries like `${events.last('redistribution.decision')}` use
method-call syntax that the `VariableResolver` cannot resolve. The
`VariableResolver` does naive dot-splitting (`name.indexOf('.')`)
which corrupts dotted event type names inside parenthesized arguments,
and `ObjectVariableSource.resolve(String)` takes a simple property
name — not a method invocation.

The resolution uses **deferred-prefix fallback to the expression
engine**:

1. The test runner registers `"events"` as a **deferred prefix** in
   the `VariableResolver`. The VariableResolver already supports
   deferred prefixes (`VariableResolver.java:118`, `:231`) — when a
   prefix is deferred, the `${...}` expression passes through
   unchanged.

2. The `assertThat` plugin detects unresolved `${...}` expressions
   in its subject and evaluates them via the **expression engine**
   (MVEL3). MVEL natively supports method invocation on Java objects.

3. `EventCapture` is registered as a named variable (`events`) in
   the expression engine context. MVEL resolves
   `events.last('redistribution.decision')` by calling the `last()`
   method directly.

4. Chained access works naturally:
   `events.last('redistribution.decision').data.reason` →
   MVEL calls `last("redistribution.decision")` → `CapturedEvent` →
   `.data` calls `data()` → `Map` → `.reason` → `Map.get("reason")`

This approach requires no changes to `VariableResolver`,
`ObjectVariableSource`, or `FieldDriller`. The deferred prefix
mechanism and expression engine are both existing infrastructure.

For simple captured variables (`${result.text}`,
`${results.succeeded}`), the VariableResolver handles resolution
directly — no expression engine involvement. The expression engine
is only invoked when the VariableResolver defers.

## Capture Mechanism

`capture:` is a new **decorator key** added to
`StepKeywords.DECORATOR_KEYS`. It binds step output to a named
variable accessible by subsequent steps.

### Syntax

```yaml
# Decorator on any step — sibling key at step level
- agent-invoke:
    prompt: "What's my risk profile?"
  capture: result

- run-playbook: examples/02-session-conversation.yaml
  capture: results
```

### Resolution

1. The Walker extracts `capture:` from the step map as a decorator
   (alongside `when:`, `timeout:`, `retry:`, etc.)
2. The step executes and returns a `Result` with an output map
3. The step execution loop (in `StructuralStepEvaluator`) processes
   the `capture` decorator: calls
   `resolver.withObjectScope(captureName, outputMap::get)` to register
   the captured output as a new variable prefix
4. The updated `VariableResolver` is passed to subsequent steps

### Variable access

Captured values are accessed via `${captureName.fieldName}`:

- `${result.text}` — field "text" from the capture named "result"
- `${results.succeeded}` — field "succeeded" from "results"
- `${results.output.risk_assessment}` — nested field access via
  `FieldDriller`

The `VariableResolver` already supports `withObjectScope(prefix,
source)` — capture is a natural use of this existing mechanism.

### Reserved names

The name `events` is reserved for event capture and cannot be used
as a `capture:` target. Using `capture: events` would collide with
the deferred `events` prefix — the VariableResolver checks deferred
prefixes before ObjectVariableSource (`VariableResolver.java:118`),
so `${events.xxx}` would be deferred to the expression engine
(where `events` is bound to EventCapture) rather than resolved via
the captured output. The step runner validates capture names and
rejects reserved names with a clear error.

### Scope

Captured variables are scoped to the enclosing step block. A capture
inside a `try:` block is not visible in the `catch:` block. A capture
inside `run-playbook` is scoped to the nested playbook's execution.

## Test Lifecycle

YAML tests support lifecycle callbacks matching JUnit's model:

### Per-test: setup: and teardown: blocks

`setup:` and `teardown:` are top-level step lists alongside `simulate:`
and `steps:`. `setup:` runs before the main steps. `teardown:` runs in
a finally block — guaranteed even on assertion failure or step error.

```yaml
name: Session with pre-seeded state

simulate:
  agent:
    - prompt: "portfolio"
      response: "60% equities."

setup:
  - emit-event: test.seed-data
    data:
      portfolio: { total: 150000 }

steps:
  - agent-invoke:
      prompt: "portfolio"
    capture: result
  - assertThat: ${result.text}
    contains: 'equities'

teardown:
  - emit-event: test.clear-data
```

Both are optional. A test with no `setup:` or `teardown:` works
exactly as before. Variables captured in `setup:` are visible in
`steps:` (the setup VariableResolver is passed to step execution).
Variables from `steps:` are NOT visible in `teardown:` — teardown
runs in its own scope to avoid depending on potentially failed state.

### Per-directory: _setup.test.yaml and _teardown.test.yaml

Convention files that run once per directory — equivalent to JUnit's
`@BeforeAll` / `@AfterAll`:

```
tutorials/01-basics/
  _setup.test.yaml           # runs once before all tests in 01-basics/
  01-invoke.test.yaml
  02-capture.test.yaml
  _teardown.test.yaml        # runs once after all tests in 01-basics/
```

`_setup.test.yaml` is a normal `.test.yaml` file — it can have its
own `simulate:` block, steps, and assertions. Its captured variables
are available to all tests in the directory via a shared
VariableResolver scope. `_teardown.test.yaml` runs after the last
test completes (or fails), in a finally block.

The `_` prefix excludes these from the test count — they are
infrastructure, not tests. The test runner reports them as lifecycle
steps, not test cases.

| JUnit | YAML equivalent | Scope |
|-------|----------------|-------|
| `@BeforeEach` / `@AfterEach` | `setup:` / `teardown:` blocks | Per-test file |
| `@BeforeAll` / `@AfterAll` | `_setup.test.yaml` / `_teardown.test.yaml` | Per-directory |

## Walker Integration

Two Walker enhancements are required for the testing step types:

### 1. Sibling-absorbing plugins

Plugins can opt into **sibling absorption** via
`@Plugin(absorbSiblings = true)`. When the Walker matches such a
plugin as the action key, remaining non-reserved keys become plugin
parameters (instead of throwing "unknown key").

Used by:
- `assertThat:` — matchers (`contains`, `equals`, etc.) as siblings
- `emit-event:` — `data:` as sibling key

The Walker collects these into the plugin's parameter map with a
`_subject` entry for the scalar value:

```yaml
- assertThat: ${response}    # _subject = "${response}"
  contains: 'equities'       # contains = "equities"
  startsWith: 'Moderate'     # startsWith = "Moderate"
```

Resolves to `PluginStep("assertThat", {_subject: "${response}",
contains: "equities", startsWith: "Moderate"}, decorators)`.

### 2. Scalar-or-map polymorphism for plugins

When a plugin's action key has a scalar value (not a Map), the scalar
is passed as `_subject` in the params map. When it has a Map value,
the Map becomes the params directly. This is the plugin equivalent of
`ShorthandModule`'s scalar-or-object pattern:

```yaml
# Scalar form — _subject = "examples/02.yaml"
- run-playbook: examples/02.yaml

# Map form — params = {file: "...", vars: {...}}
- run-playbook:
    file: examples/02.yaml
    vars:
      portfolio: conservative
```

## Test Runner

### JUnit Platform TestEngine

`YamlTestEngine implements TestEngine`:

- `getId()` → `"casehub-yaml"`
- `discover(request)` — scans `src/test/resources/**/*.test.yaml`,
  builds `TestDescriptor` tree (directory = container, file = test)
- `execute(request, listener)` — for each test descriptor:
  push overlay → compile → execute → pop → report

Convention-based ordering: directories and files sorted by name prefix
(`01-basics/` before `02-sessions/`, `01-invoke.test.yaml` before
`02-session.test.yaml`).

JUnit XML output is handled by the JUnit Platform — no custom
reporter needed. IntelliJ discovers tests natively via the TestEngine
SPI.

Maven integration via existing `maven-surefire-plugin` configuration:

```xml
<dependency>
  <groupId>io.casehub</groupId>
  <artifactId>casehub-platform-yaml-test</artifactId>
  <scope>test</scope>
</dependency>
```

No plugin configuration needed — Surefire auto-discovers TestEngine
implementations on the test classpath.

### Standalone CLI

`YamlTestCli` — thin wrapper around the test engine core:

```bash
casehub-test src/test/resources/tutorials/
casehub-test --filter "01-*" src/test/resources/
casehub-test --report junit-xml --output reports/ .
```

Shares `YamlTestExecutor` with the TestEngine — both call the same
core: discover → overlay → execute → report.

### CLI compatibility

The CLI runs tests without a CDI container. This limits which test
levels are executable:

| Level | CLI | JUnit/Quarkus | Reason |
|-------|-----|---------------|--------|
| 1-3 | yes | yes | Simulation-only — no reactive application behaviour |
| 4 | no | yes | Reactive events require CDI event bus + application handlers |
| 5 | partial | yes | Agent simulation works; REST simulation requires CDI wiring |

Level 4 tests emit events and assert on events produced **by
application code in response**. Without CDI, application event
handlers don't run, so reactive events are never produced. The CLI
reports these tests as `SKIPPED: requires CDI context` rather than
failing silently.

### Error reporting

Test failures include:

1. **Test name and file** — click-to-navigate in IntelliJ
2. **Step number and name** — which step failed
3. **Subject, actual value, and failed matchers** — what was checked, what was found
4. **Simulation context** — which corpus entries were matched/unmatched
5. **Stack trace** — for infrastructure errors (not assertion failures)

```
FAIL: tutorials/02-sessions/01-context.test.yaml
  "Session preserves conversation context"
  Step 5: assertThat: ${rebalance}
    Subject: ${rebalance}
    Actual: "I don't have enough context to answer that."
    Failed:
      contains: 'bonds' — actual value does not contain 'bonds'
  Simulation: agent corpus matched 1/2 entries
    ✓ "risk profile" → matched
    ✗ "rebalancing" → no match (closest: "risk profile", score: 0.34)
```

The "simulation context" section is critical — it shows whether the
test failed because the assertion is wrong or because the corpus
didn't match the prompt (the most common test authoring error).

## Module Layout

### yaml-test-core

Framework-neutral POJO. No CDI, no Spring.

- `YamlTestDiscovery` — finds `*.test.yaml` files, builds test tree
- `YamlTestExecutor` — overlay push → resolve (Walker) → execute →
  pop → result
- `SimulateBlockParser` — parses `simulate:` block, resolves aliases,
  normalises fields, builds `SimulationOverlay`
- `EventCapture` — POJO CloudEvent collector (not a CDI observer).
  Receives events pushed to it; provides query methods (`ofType`,
  `last`, `count`) for assertion expressions
- `TestResult` — pass/fail/error with structured failure info
- `TestReport` — JUnit XML generation
- `YamlTestCli` — standalone CLI entry point

Dependencies: `yaml-core`, `yaml-step-runtime` (Walker,
CatalogStepRunner, PluginRegistry), `simulation-core`,
`simulation-config-core`.

Note: no dependency on `playbook-compiler` — test execution uses the
Walker path, not the SWF compilation path.

### yaml-test

Quarkus CDI wiring + JUnit Platform.

- `YamlTestEngine implements TestEngine` — JUnit Platform integration
- `YamlTestBeans` — `@Produces` wiring for test executor with CDI
  `SimulationRuntime`, `PluginRegistry`, expression engines
- `TestEventCapture @ApplicationScoped` — CDI observer (`@Observes
  CloudEvent`) that forwards events to the test-scoped `EventCapture`
  POJO. This bridges CDI events from application code into the test
  capture scope.

Dependencies: `yaml-test-core`, JUnit Platform Engine API, Quarkus
test framework.

### Relationship with yaml-step-testing

`yaml-step-testing` is an **internal test utility** for the step
runtime module itself — it provides `FaultInjectingStepRunner` for
testing the step pipeline's retry/error handling. It serves a
different purpose from `yaml-test-core`:

| Module | Purpose | Scope |
|--------|---------|-------|
| `yaml-step-testing` | Test the step runtime internals | Developer testing of platform code |
| `yaml-test-core` | Run `.test.yaml` declarative tests | User-facing test framework |

They do not depend on each other. `yaml-step-testing`'s WireMock
integration is orthogonal to `yaml-test`'s simulation-based approach —
simulation intercepts at the SPI layer, WireMock intercepts at the
HTTP layer.

## Simulation Alignment

### What collapses

The temporal driving layer becomes unnecessary:

| Before | After |
|--------|-------|
| `TemporalSimulationDriver` state machine | Playbook executor (already has state machine) |
| `TimedSequence` + `TimedEntry` | Playbook steps: `delay:` + `emit-event:` |
| `TemporalProfile` | A playbook file |
| `TemporalDriverService` MCP domain | Run a playbook (standard executor) |
| `EventSequenceRunner` | Playbook with `emit-event:` steps |
| `FeedBinding` (temporal → OrcChannel) | Playbook `emit-event:` → CDI bus → OrcChannel |

### What stays

The corpus/strategy layer is data, not orchestration:

- `SimulationRuntime` — strategy resolution, overlay stack, journal
- `YamlSimulationConfig` — YAML parsing for simulation.yaml
- `SimulationStrategy` implementations (Sequential, KeyLookup, etc.)
- `SimulationCorpus` — stores invocation records
- `SimulationVerifier` — assertion on invocation journal
- `@SimulationEligible` + APT-generated `@Decorator` — SPI interception

### Migration path

1. Build `emit-event:` plugin step
2. Rewrite temporal profiles as playbook files
3. Replace `TemporalDriverService` MCP operations with playbook
   execution — tracked in #687
4. Deprecate `TemporalSimulationDriver`, `TimedSequence`,
   `EventSequenceRunner` — tracked in #687
5. Remove after consumers migrate — tracked in #687

Steps 3-5 are deferred work tracked under #687 (temporal collapse).
The testing framework (this spec) enables steps 1-2; the deprecation
and removal phases are scoped to #687's implementation.

## Tutorials as Tests

Tutorial structure follows convention-based ordering:

```
src/test/resources/tutorials/
  01-basics/
    01-invoke.test.yaml          # Single agent call
    02-capture.test.yaml         # Capturing output
    03-assert.test.yaml          # Writing assertions
  02-sessions/
    01-open-close.test.yaml      # Session lifecycle
    02-context.test.yaml         # Multi-turn context
  03-events/
    01-emit.test.yaml            # Firing events
    02-temporal.test.yaml        # Timed sequences
  04-advanced/
    01-tool-use.test.yaml        # Agent tool use
    02-mixed-simulation.test.yaml # Multiple SPI simulation
```

Each file is self-contained — a reader can open any tutorial and
understand it without reading others. Levels progress in complexity
but don't share state.

The test runner executes in directory order, reports per-level results:

```
tutorials/01-basics/     3/3 passed
tutorials/02-sessions/   2/2 passed
tutorials/03-events/     2/2 passed
tutorials/04-advanced/   1/2 FAILED
```

## Helpdesk Migration Target

Helpdesk becomes the first 100% YAML application with 100% YAML tests.
Migration validates:

- Every Java test assertion has a YAML equivalent
- No coverage loss (diff audit before deleting Java)
- Tutorial tests serve as onboarding documentation
- CI runs YAML tests via `mvn test` with no extra configuration

**Prerequisite for #688:** an inventory of existing Java tests (test
count, modules, assertion types) must be completed before migration
begins. The inventory establishes the coverage baseline and identifies
any Java assertions that need YAML equivalents not yet available.

## Issue Mapping (revised)

The original epic had 5 child issues. Based on this design:

| Original | Revised scope |
|----------|--------------|
| #684 (corpus wiring) | SimulateBlockParser + alias resolution — SimulatedAgentBackend already exists |
| #685 (assert + run-playbook) | New `assertThat` @Plugin (sibling-key matchers, two-phase subject resolution) + `agent-invoke` step type (@Plugin + StepCompiler) + `run-playbook` @Plugin + `emit-event` @Plugin + `verify-simulation` @Plugin + Walker sibling-absorption enhancement + `capture:` decorator key addition to `StepKeywords.DECORATOR_KEYS` |
| #686 (test runner) | YamlTestEngine (JUnit Platform) + YamlTestCli + EventCapture |
| #687 (temporal collapse) | emit-event plugin + temporal profile migration + TemporalDriverService deprecation |
| #688 (migration) | Rewrite Java tests + helpdesk migration + coverage audit |

## References

- `simulation-core/` SimulationRuntime, TemporalSimulationDriver
- `simulation-config-core/` YamlSimulationConfig, CorpusLoader
- `event-simulation-core/` EventSequenceRunner, CloudEventFixtureBuilder
- `event-simulation/` TemporalDriverService MCP domain
- `yaml-step-runtime/` Walker, StepRunner, AssertPlugin
- `playbook-compiler/` PlaybookCompiler, StepCompiler registry
- `schema-generator/` ShorthandModule (scalar-or-object polymorphism)
- feat-294 spec D43-47 (simulation overlay isolation)
- issue-391 spec D14 (four-tier escape model, YAML capability equivalence)
- issue-600 spec (event sequence patterns)
- #669 (PlaybookProtocolEvaluator deletion precedent)
