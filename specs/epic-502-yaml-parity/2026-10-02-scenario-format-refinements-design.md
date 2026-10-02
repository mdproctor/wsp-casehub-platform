# Scenario Format Refinements — Design Spec

**Issue:** casehub-pages#390
**Date:** 2026-10-02
**Branch:** epic-502-yaml-parity

## Problem

The scenario system has two Java parsers (ScenarioParser, HierarchicalParser)
producing two incompatible type hierarchies, and a TS parser that diverged
from both. The Java HierarchicalParser introduced a bespoke 3-level format
(steps → commands[]) that duplicates what the standard Walker/plugin catalog
already does. The compact step syntax (action-name-as-key) used by the TS
side, the engine's `do:` blocks, and the plugin system is the established
pattern everywhere else in casehub.

## Solution

Delete both Java parsers. Write a single scenario envelope parser that reads
the presentation structure and delegates step resolution to the standard
Walker/plugin catalog. Converge the YAML format so one compact syntax is
used everywhere.

### Unified YAML Format

```yaml
scenario: helpdesk-intake
actor: system
speed: 1.0
meta:
  description: "Demonstrate ticket intake workflow"
  labels: [domain:helpdesk]

sections:
  - label: "Submit a ticket"
    content: "Walk through the intake form"
    do:
      - navigate:
          value: "#intake"

      - fill:
          role: textbox
          name: "Subject"
          value: "Network connectivity issue"
        label: "Fill ticket subject"

      - select:
          role: combobox
          name: "Priority"
          value: "high"

      - spotlight:
          role: combobox
          name: "Priority"
          content: "Priority drives SLA timers"

      - click:
          role: button
          name: "Submit"
```

- `do:` instead of `steps:` (consistent with engine and parity work)
- Action-name-as-key with flat params (standard plugin format)
- Decorators as sibling keys: `label:`, `target:` (executor), `actor:`,
  `delay:`, `when:`, `speed:`
- Speed omitted = no inter-step delay (opt-in pacing via explicit `speed:`)
- Scenario-level `actor:` is the default; step-level `actor:` overrides

### What Gets Deleted

**Java (pages/backend/scenario/):**
- `ScenarioParser.java` — Format A parser
- `ScenarioStep.java` — sealed interface (AriaStep/GraphQLStep/SimulatedStep/RestStep)
- `ScenarioCommand.java` — bespoke command record
- `HierarchicalParser.java` — bespoke 3-level parser
- `HierarchicalStep.java` — bespoke step record with commands[]
- All test files for the above

### What Gets Created

**`ScenarioEnvelopeParser.java`** — single clean replacement:
- Reads envelope: scenario name, speed (default: no delay), actor, meta,
  simulation, slides
- Reads structure: chapters → sections → `do:` blocks (ScenarioStructure)
- Delegates each `do:` block to the standard Walker/plugin catalog for
  step resolution
- No step parsing, no command parsing, no AriaTarget parsing

**`ScenarioEnvelope.java`** — record holding parsed envelope + structure.
Replaces HierarchicalScenario. Fields: scenario, description, speed, actor,
onError, params, meta, data, iterations, slides, simulation, chapters,
sections, steps (resolved by Walker).

### Plugin Taxonomy

Three plugin categories, all using yaml-plugin-api:

| Category | Examples | Runtime | Executor routing |
|---|---|---|---|
| AriaStep | fill, click, navigate, spotlight, scroll-to-row | Browser DOM | Implicit → browser |
| ScenarioStep | show-markdown, callout, slide | Presentation | Implicit → browser |
| ScenarioStructure | chapter, section | Parse-time | Not dispatched |

Registered through `@StepPlugin`. Plugin `portability` field carries the
category for executor routing. Default routing inferred from category;
`target:` decorator overrides per-step.

### REST/GraphQL as Plugins

RestDispatcher and GraphQLDispatcher adapted as standard step plugins:

```yaml
- rest:
    method: POST
    url: https://api.internal/cases
    headers:
      Authorization: "Bearer ${token}"
    body:
      subject: "${subject}"
    expected-status: 201

- graphql:
    domain: cases
    operation: createCase
    params:
      subject: "${subject}"
```

The dispatch logic from the existing dispatchers is preserved; the Format A
type wrappers (ScenarioStep.RestStep, ScenarioStep.GraphQLStep) are deleted.

### Wire Protocol Changes

When the Java orchestrator serializes steps for browser executor dispatch:
- `target` (AriaTarget) renamed to `element` in the JSON payload
- TS `ScenarioCommand` interface: `target → element`
- TS `scenario-handler.ts`: reads `element` field

In the YAML format itself, ARIA element fields remain flat (role, name,
index, within) — no wrapping object. The rename only affects the
serialized wire protocol.

### Semantic Constraints

**`await:` validation:** Only permitted on actions whose plugin definition
declares them as idempotent/query operations. Mutations rejected at parse
time. Prevents duplicated side effects from poll cycles.

**Result aggregation:** Last-write-wins merge. Intra-step variable references
(`${thisStep.field}`) prohibited. Compose via sequential steps with variable
references instead.

### TS Changes

- `parseScenarioFromParsed()` → reads `do:` instead of `steps:`
- `ScenarioCommand` interface: `target → element`
- `scenario-handler.ts`: updated dispatch to read `element`
- `types.ts`: consolidated with working types from scenario-handler.ts

### YAML Migration

All existing YAML files using the commands[] format migrated to compact
format. Known files:
- `META-INF/scenarios/helpdesk-intake.yaml`
- Test resource YAML files in `backend/scenario/src/test/resources/`

## Testing

**Java:**
- ScenarioEnvelopeParser: envelope fields, chapters/sections/do structure,
  Walker delegation
- Speed default: omitted = no delay, explicit = pacing
- Actor inheritance: scenario-level default, step-level override
- Delay decorator on steps
- REST/GraphQL plugins: catalog resolution and dispatch
- await validation: rejected on mutations, accepted on queries
- Migrated YAML files parse through new parser

**TS:**
- Wire protocol: `element` field in ScenarioCommand
- `do:` parsing in parseScenarioFromParsed
- Types consolidation

**Integration:**
- Scenario YAML → Java envelope parser → Walker step resolution →
  browser executor dispatch → TS command execution

## Out of Scope

- Playbook naming unification (parked for post-epic)
- Multi-executor routing table (future, when distributed scenarios need it)
- TS-side Walker changes (already uses compact format)
- Orchestration primitives (barriers, channels, state machines — unchanged)

## References

- `backend/scenario/src/main/java/.../HierarchicalParser.java` — bespoke 3-level parser (329 lines, being deleted)
- `backend/scenario/src/main/java/.../ScenarioCommand.java` — bespoke command record (being deleted)
- `backend/scenario/src/main/java/.../ScenarioParser.java` — Format A parser (being deleted)
- `backend/scenario/src/main/java/.../ScenarioStep.java` — sealed interface (being deleted)
- `backend/scenario-runtime/src/main/java/.../ScenarioOrchestrator.java` — serializes steps (wire protocol rename)
- `packages/pages-aria/src/scenario/parser.ts` — TS parser (already uses Walker delegation)
- `packages/pages-aria/src/server/scenario-handler.ts:18-25` — ScenarioCommand interface (target → element)
- `packages/pages-aria/src/scenario/types.ts` — TS types (consolidation)
- `engine/examples/yaml/sequential-onboarding.yaml` — engine do: blocks (established compact pattern)
- `META-INF/scenarios/helpdesk-intake.yaml` — commands[] format (migration target)
- `backend/scenario/src/test/resources/scenarios/helpdesk-demo.yaml` — Format A (already compact)
- Decisions D18–D26 in decisions.md
- casehub-pages#390, casehubio/parent#409, casehubio/parent#408
