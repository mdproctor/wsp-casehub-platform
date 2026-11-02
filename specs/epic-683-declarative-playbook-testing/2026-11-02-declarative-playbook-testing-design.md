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
2. **Declarative testing infrastructure** — expression-based assertions,
   run-playbook step, emit-event step, JUnit Platform TestEngine + CLI
3. **Migration** — rewrite Java integration tests as `.test.yaml` files,
   helpdesk as first 100% YAML app + 100% YAML test target

## Core Model

A `.test.yaml` file is a regular playbook with one addition: a
`simulate:` top-level block that configures which SPI calls return
simulated responses. The test runner:

1. Discovers `*.test.yaml` by convention
2. Parses as `PlaybookDocument` with `simulate:` section
3. Pushes a `SimulationOverlay` onto `SimulationRuntime`
4. Compiles and executes the playbook steps
5. Pops the overlay
6. Reports pass/fail based on assert step outcomes

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
  - assert: ${result.text} contains 'equities'
```

### Level 2 — Session with multiple turns

```yaml
name: Session preserves conversation context

simulate:
  agent:
    - prompt: "risk profile"
      response: "Moderate risk: 60% equities."
    - prompt: "rebalancing"
      response: "Shift 10% equities to bonds."

steps:
  - agent-session-open:
      pool: financial-advisor
      capture: session
  - agent-session-query:
      session: ${session}
      prompt: "What's my risk profile?"
      capture: risk
  - assert: ${risk} contains 'equities'
  - agent-session-query:
      session: ${session}
      prompt: "How should I rebalance?"
      capture: rebalance
  - assert: ${rebalance} contains 'bonds'
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
  - assert: ${results.succeeded}
  - assert: ${results.output.risk_assessment} contains 'equities'
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
  - assert: ${events.last('redistribution.decision')} != null
  - assert: ${events.last('redistribution.decision').data.reason} contains 'threshold'
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
  rest:
    - url: /api/portfolio
      method: GET
      response:
        status: 200
        body: { total: 150000, equities: 90000 }

steps:
  - run-playbook: examples/05-tool-use-patterns.yaml
    capture: results
  - assert: ${results.succeeded}
  - assert: ${results.stepCount} >= 4
  - assert: ${results.output.portfolio_summary} contains 'equities'
```

## Simulate Block

### Alias resolution

The simulate block uses domain aliases that resolve to qualified SPI
method names with sensible defaults:

| Alias | Resolves to | Default strategy | Default key-extractor |
|-------|-------------|------------------|-----------------------|
| `agent` | `agent-provider.invoke` | `key` | `field:user-prompt` |
| `rest` | REST client simulation | `key` | `field:url` |

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
| `rest` | `url` / `response` | `key` / `output` |

### Corpus sources

Three modes, combinable:

```yaml
simulate:
  agent:
    # Inline entries — self-contained, good for tutorials
    - prompt: "question"
      response: "answer"

  agent:
    # External file — shared across tests
    corpus-file: corpora/financial-qa.yaml

  agent:
    # Mixed — external base + test-specific overrides
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

No new infrastructure — reuses the overlay stack from feat-294 (D43-47).

## Step Types

### assert (existing — enhanced)

Extends the existing `AssertPlugin` with expression functions for
testing:

```yaml
# Short form — expression as scalar value
- assert: ${response} contains 'equities'

# With message
- assert:
    expression: ${response} contains 'equities'
    message: "Risk assessment should mention equities"
```

New expression functions added to the expression engine:

| Function | Example | Description |
|----------|---------|-------------|
| `contains(a, b)` | `${x} contains 'foo'` | String/collection contains |
| `equals(a, b)` | `${x} equals 'foo'` | Equality check |
| `matches(a, pattern)` | `${x} matches '\\d+'` | Regex match |
| `hasSize(a, n)` | `${list} hasSize 3` | Collection size |
| `isEmpty(a)` | `isEmpty(${list})` | Empty check |
| `isTrue(a)` | `isTrue(${flag})` | Boolean truth |
| `startsWith(a, b)` | `${x} startsWith 'prefix'` | String prefix |

Assertion failures produce structured error messages:

```
AssertionFailed: step 4 of "Verify session example"
  Expression: ${results.output.risk_assessment} contains 'equities'
  Actual value: "The portfolio is balanced."
  Expected: to contain 'equities'
```

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
| `events` | List | Step execution events |
| `error` | String | Error message if failed (null if succeeded) |

Scalar-or-object polymorphism via `ShorthandModule`:
- String value → file path (shorthand)
- Map value → full form with file, vars, capture

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
CDI event bus. Scalar-or-object polymorphism: string value → event
type, map value → full CloudEvent spec.

## Event Capture

Tests need to assert on events fired during playbook execution. An
`EventCapture` is automatically active during test execution:

- Records all CloudEvents fired via the CDI event bus
- Accessible in expressions via `${events}` variable
- Query functions: `events.ofType('capacity.pressure')`,
  `events.last('redistribution.decision')`, `events.count('type')`

Captures CloudEvents only (not arbitrary CDI events). No explicit
start/stop — capture is scoped to the test execution (pushed/popped
with the simulation overlay).

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

### Error reporting

Test failures include:

1. **Test name and file** — click-to-navigate in IntelliJ
2. **Step number and name** — which step failed
3. **Expression and actual value** — what was checked, what was found
4. **Simulation context** — which corpus entries were matched/unmatched
5. **Stack trace** — for infrastructure errors (not assertion failures)

```
FAIL: tutorials/02-sessions/01-context.test.yaml
  "Session preserves conversation context"
  Step 5: assert: ${rebalance} contains 'bonds'
    Actual: "I don't have enough context to answer that."
    Expected: to contain 'bonds'
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
- `YamlTestExecutor` — overlay push → compile → execute → pop → result
- `SimulateBlockParser` — parses `simulate:` block, resolves aliases,
  normalises fields, builds `SimulationOverlay`
- `TestResult` — pass/fail/error with structured failure info
- `TestReport` — JUnit XML generation
- `YamlTestCli` — standalone CLI entry point
- `EventCapture` — CDI event recording scoped to test execution

Dependencies: `yaml-core`, `simulation-core`, `simulation-config-core`,
`playbook-compiler`.

### yaml-test

Quarkus CDI wiring + JUnit Platform.

- `YamlTestEngine implements TestEngine` — JUnit Platform integration
- `YamlTestBeans` — `@Produces` wiring for test executor with CDI
  `SimulationRuntime`, `PluginRegistry`, expression engines
- `TestEventCapture @ApplicationScoped` — CDI observer that records
  CloudEvents during test execution

Dependencies: `yaml-test-core`, JUnit Platform Engine API, Quarkus
test framework.

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
   execution
4. Deprecate `TemporalSimulationDriver`, `TimedSequence`,
   `EventSequenceRunner`
5. Remove after consumers migrate

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

## Issue Mapping (revised)

The original epic had 5 child issues. Based on this design:

| Original | Revised scope |
|----------|--------------|
| #684 (corpus wiring) | SimulateBlockParser + alias resolution — SimulatedAgentBackend already exists |
| #685 (assert + run-playbook) | Extend AssertPlugin with expression functions + run-playbook @Plugin + emit-event @Plugin |
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
