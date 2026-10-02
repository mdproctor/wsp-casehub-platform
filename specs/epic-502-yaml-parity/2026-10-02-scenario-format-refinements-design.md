# Scenario Format Refinements — Design Spec

**Issue:** casehub-pages#390 (scope expanded by decisions D18–D26)
**Date:** 2026-10-02
**Branch:** epic-502-yaml-parity

## Problem

The scenario system has two Java parsers (ScenarioParser, HierarchicalParser)
producing two incompatible type hierarchies. The TS-side unification is
complete — issue #507 is closed, and `parseScenarioFromParsed()` in
`pages-aria/src/scenario/parser.ts` already delegates to `Walker.resolve()`
from yaml-core. The remaining gap is Java-side convergence.

The Java HierarchicalParser introduced a bespoke 3-level format
(steps → commands[]) that duplicates what the standard Walker/plugin catalog
already does on the TS side. The compact step syntax (action-name-as-key)
used by the TS parser, the engine's `do:` blocks, and the plugin system is
the established pattern everywhere else in casehub. The Java parser should
converge to the same compact format so one YAML syntax is used everywhere.

**Note:** Issue #390's original scope was refinements to the existing model.
Decisions D18–D26 (in decisions.md) expanded the scope to full format
convergence during design investigation. The issue body needs updating to
match the decisions.

## Solution

Delete both Java parsers. Write a single scenario envelope parser that reads
the presentation structure and passes compact-format step data through to the
orchestrator for dispatch. Converge the YAML format so one compact syntax is
used everywhere.

### Unified YAML Format

**Sectioned format (tutorials, demos):**

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
    steps:
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

**Flat format (automations, scripts):**

```yaml
scenario: helpdesk-demo
steps:
  - navigate: /helpdesk/intake

  - fill:
      role: textbox
      name: "Customer Name"
      value: "Alice Chen"

  - click:
      role: button
      name: "Submit"
```

Key format properties:
- `steps:` as the step-list key (both top-level and inside sections)
- Action-name-as-key with flat params (standard plugin format)
- Decorators as sibling keys: `label:`, `step:` (naming), `target:` (executor),
  `actor:`, `delay:`, `when:`, `speed:`, `forEach:`
- Speed omitted = no inter-step delay (opt-in pacing via explicit `speed:`)
- Scenario-level `actor:` is the default; step-level `actor:` overrides
- `steps:` and `sections:` are mutually exclusive at top level
  (chapters contain sections; sections contain steps)

### What Gets Deleted

**Java (pages/backend/scenario/):**
- `ScenarioParser.java` — Format A parser
- `ScenarioStep.java` — sealed interface (AriaStep/GraphQLStep/SimulatedStep/RestStep)
- `ScenarioCommand.java` — bespoke command record
- `HierarchicalParser.java` — bespoke 3-level parser
- `HierarchicalStep.java` — bespoke step record with commands[]
- `AriaTarget.java` — bespoke ARIA target record (params become flat step keys)
- All test files for the above

### What Gets Created

**`ScenarioEnvelopeParser.java`** — single clean replacement:
- Reads envelope: scenario name, speed (default: no delay), actor, meta,
  simulation, slides, onError, params, data, iterations
- Reads structure: chapters → sections → `steps:` arrays
- Extracts step data as raw maps: each step is {actionName → params} plus
  decorator sibling keys
- Does NOT resolve steps through a catalog — the Java side is a pass-through.
  Step resolution happens on the TS executor side via Walker.resolve()
- ForEach expansion and variable interpolation remain in the ScenarioCompiler
  pipeline (see §Data-Driven Features below)

**`ScenarioEnvelope.java`** — record holding parsed envelope + structure.
Replaces HierarchicalScenario. Fields:

| Field | Description | Source |
|---|---|---|
| `scenario` | Scenario name (required) | Top-level `scenario:` key |
| `description` | Human-readable description | Top-level or `meta.description` |
| `speed` | Inter-step delay multiplier (default: 0 = no delay) | Top-level `speed:` |
| `actor` | Default authentication identity | Top-level `actor:` |
| `onError` | Error handling strategy ("stop" halts on first failure) | Top-level `on-error:` |
| `params` | Declared parameters with type/required/default | Top-level `params:` block |
| `meta` | Labels, tags, description | Top-level `meta:` block |
| `data` | Inline data sources (CSV, map) for forEach | Top-level `data:` block |
| `iterations` | Named iteration groups for forEach | Top-level `iterations:` block |
| `slides` | Slide deck reference for presentation | `content.slides` |
| `simulation` | Simulation overlay config (strategies, corpus, capture) | Top-level `simulation:` block |
| `chapters` | Chapter containers (label, content, sections) | Top-level `chapters:` array |
| `sections` | Section containers (label, content, steps) | Top-level `sections:` array |
| `steps` | Flat step list (raw maps, not resolved) | Top-level `steps:` array |

### Plugin Taxonomy

Two plugin categories, using yaml-plugin-api:

| Category | Examples | Runtime | Executor routing |
|---|---|---|---|
| AriaStep | fill, click, navigate, spotlight, scroll-to-row | Browser DOM | Implicit → browser |
| ScenarioStep | show-markdown, callout, slide, rest, graphql | Presentation / Server | Explicit via `target:` decorator |

Registered through `@Plugin` annotation (from `io.casehub.yaml.plugin.api`).
Plugin `portability` field indicates execution environment (JAVA, TS, BOTH,
UNIVERSAL). Default routing inferred from portability; `target:` decorator
overrides per-step.

Chapters and sections are **structural containers**, not plugins. They are
parsed directly by the envelope parser — they do not appear in the plugin
catalog, are not resolved by the Walker, and have no `@Plugin` annotation or
`@Execute` method.

**Relationship to `@ScenarioAction`:** The existing `@ScenarioAction`
annotation (in `scenario-client`) is the CDI-based handler for the current
wire protocol. REST and GraphQL handlers use this annotation. As the
scenario system converges with the platform plugin model, `@ScenarioAction`
handlers will be adapted to receive step params from the new compact format
instead of `ScenarioCommand` fields. The migration path is:
1. New envelope parser produces raw step maps (action name + params)
2. Orchestrator serializes these for dispatch
3. Executor client routes to `@ScenarioAction` handlers using action name
4. Future: `@ScenarioAction` converges with `@Plugin` as the scenario
   executor framework matures

### REST/GraphQL as Plugins

RestDispatcher and GraphQLDispatcher adapted as standard step plugins:

```yaml
- step: create-case
  rest:
    method: POST
    url: https://api.internal/cases
    headers:
      Authorization: "Bearer ${token}"
    body:
      subject: "${subject}"
    expected-status: 201

- step: inject-chat
  graphql:
    domain: connectors
    operation: injectChat
    params:
      platform: "slack"
      sender: "Alice"
      text: "My laptop won't boot"

- step: verify-classified
  graphql:
    domain: engine
    operation: caseContext
    params:
      caseId: "${create-case.id}"
  await:
    match:
      category: "HARDWARE"
    timeout: 30000
    interval: 500
```

The `step:` decorator names the step for result capture. Subsequent steps
reference results via `${stepName.field}` — e.g., `${create-case.id}`.

**Step result store:** Each named step (`step: name`) captures its execution
result. Results are stored in a session-scoped result map keyed by step name.
Variable interpolation (`${stepName.field}`) resolves against this map at
execution time. The ScenarioOrchestrator already maintains `stepResults`
(ConcurrentHashMap); the compiler's VariableResolver threads results
through `${step.field}` references.

The dispatch logic from the existing dispatchers is preserved; the Format A
type wrappers (ScenarioStep.RestStep, ScenarioStep.GraphQLStep) are deleted.

### Data-Driven Features

ForEach expansion, when-conditionals, and iteration groups are handled by the
**ScenarioCompiler** pipeline — not by the parser and not by the Walker.
The pipeline is:

1. **EnvelopeParser** reads `data:`, `iterations:`, `params:` from the
   envelope and `forEach:`, `when:` as decorator keys on steps
2. **ScenarioCompiler** processes the parsed envelope:
   - Validates declared params against caller-supplied values
   - Builds `CsvDataSource` instances from `data:` blocks
   - Builds `IterationGroup` instances from `iterations:` blocks
   - Calls `ForEachExpander.expand()` with the step list, iteration groups,
     CSV sources, and a VariableResolver
   - Evaluates `when:` conditions via `Truthiness`
   - Expands forEach steps into concrete stamped steps
3. **Orchestrator** dispatches the expanded (flattened) step list

This pipeline already exists — `ScenarioCompiler.java` uses
`ForEachExpander`, `ForEachDirective`, `CsvDataSource`, `VariableResolver`,
`Truthiness`, and `ScenarioStepAdapter` from yaml-core. The only change is
the step representation: instead of `HierarchicalStep` + `ScenarioCommand`,
the adapter works with raw step maps (action-name-as-key + params). The
`ScenarioStepAdapter` is updated to stamp raw step maps instead of
`HierarchicalStep` records.

**Example (data-driven steps in compact format):**

```yaml
scenario: onboard-team-members
params:
  - name: teamName
    type: string
    required: true
data:
  members:
    inline: |
      name:string,email:string,role:string,admin:boolean
      Alice Chen,alice@example.com,Developer,true
      Bob Martin,bob@example.com,Viewer,false
steps:
  - fill:
      role: textbox
      name: "Full Name"
      value: "${each.member.name}"
    label: "Create member account"
    target: browser
    forEach:
      as: member
      in: members

  - click:
      role: button
      name: "Grant Admin"
    label: "Grant admin access"
    target: browser
    forEach:
      as: member
      in: members
    when: "${each.member.admin}"
```

### Scenario Includes

Parameterized scenario includes use the `IncludeExpander` (already
implemented in both TS yaml-core and Java ScenarioCompiler). The `call`
action from Format A is replaced by the standard include mechanism:

```yaml
includes:
  - template: seed/create-user
    params:
      userName: "Alice"
      userRole: "Admin"
```

Include expansion happens as a pre-processing phase before step resolution
(D7 in decisions.md). The `IncludeExpander` loads templates, substitutes
parameters via `VariableResolver`, and inlines the expanded steps. Nested
includes with cycle detection are supported (D10).

For backward compatibility during migration, existing `action: call` +
`script:` patterns are handled by the `ScenarioCompiler.inlineCalls()`
method, which remains until all YAML files are migrated to the include
format.

See decisions D5–D12 in decisions.md for full include design rationale.

### Wire Protocol Changes

When the Java orchestrator serializes steps for browser executor dispatch:
- `target` (AriaTarget) renamed to `element` in the JSON payload
- TS interfaces updated:
  - `ScenarioCommand` interface (scenario-handler.ts:18-25): `target → element`
  - `CommandPayload` interface (scenario-handler.ts:9-16): `target → element`
- Java `ScenarioOrchestrator.serializeSteps()` updated to write `element`
  instead of `target` for ARIA element data

**Orchestrator serialization change:** The orchestrator currently serializes
`HierarchicalStep` + `ScenarioCommand` into JSON with `commands[]` arrays.
With the compact format, serialization changes to emit the raw step map
directly: `{action: "fill", element: {role: "textbox", name: "Subject"},
value: "..."}`. The `commands[]` wrapper is removed — each step IS one
action.

In the YAML format itself, ARIA element fields remain flat (role, name,
index, within) — no wrapping object. The rename only affects the
serialized wire protocol.

### Semantic Constraints

**`await:` validation:** `await:` with `match:` is a **poll-based retry
pattern** — it re-invokes the operation on each poll cycle. This is only
safe on idempotent/query operations. Mutations must not be polled.

However, `await:` without `match:` (e.g., `await: { status: 201 }`) is
**response validation** — it checks the response of a single invocation.
This is safe on any operation, including mutations. The spec distinguishes:

| Pattern | Behavior | Allowed on mutations |
|---|---|---|
| `await: { match: {...}, timeout, interval }` | Poll-retry until match | No — rejected at parse time |
| `await: { status: N }` | Single-invocation response check | Yes |

**Result aggregation:** Each step is a single action in the compact format.
Multi-action grouping (via `block:`) follows standard Walker semantics.
Last-write-wins merge for block results. Intra-step variable references
(`${thisStep.field}`) prohibited. Compose via sequential steps with variable
references instead.

### TS Changes

- `parseScenarioFromParsed()` — already reads `steps:` (no rename needed)
- `ScenarioCommand` interface: `target → element`
- `CommandPayload` interface: `target → element`
- `scenario-handler.ts`: updated dispatch to read `element`
- `types.ts`: consolidated with working types from scenario-handler.ts

### YAML Migration

All existing YAML files using the commands[] format migrated to compact
format. Full scope:

**Production YAML files (META-INF/scenarios/):**
- `helpdesk-intake.yaml` — commands[] format → compact
- `environment-setup.yaml` — commands[] with `forEach: regions`, `iterations:`
- `onboard-team-members.yaml` — commands[] with `forEach`, `when`, inline `data`

**Tutorial files (tutorials/):**
- `tutorials/form-automation/tutorial.yaml` — sections with `steps:` (format OK,
  steps already empty or simple)
- `tutorials/yaml-composition/tutorial.yaml` — 17 `steps:` blocks
- `tutorials/architecture-concepts/tutorial.yaml` — 7 `steps:` blocks

**Test resource YAML files (backend/scenario/src/test/resources/scenarios/):**
- `helpdesk-demo.yaml` — already compact format (no migration needed)
- `hybrid-helpdesk-demo.yaml` — already compact format (REST/GraphQL refs
  need updating to use `rest:`/`graphql:` as action keys instead of
  `delivery:` sibling)
- `caller-script.yaml` — `action: call` with parameterized includes
- `callee-create-user.yaml` — parameterized callee
- `foreach-csv-inline.yaml` — forEach + when with CSV data
- `parameterized-onboard.yaml` — parameterized steps
- `cyclic-a.yaml`, `cyclic-b.yaml` — cycle detection tests
- `environment-setup.yaml` (test copy)

**Files already in compact format (no migration needed):**
- `helpdesk-demo.yaml` — flat steps with action-name-as-key

## Simulation

The `simulation:` block in the envelope provides overlay configuration for
the platform's SimulationRuntime. The envelope parser reads:

```yaml
simulation:
  strategies:
    correlator: "random"
    classifier: "rule-based"
  corpus:
    - "classpath:corpus/helpdesk-tickets.yaml"
  capture:
    - "case.created"
    - "case.classified"
```

- `strategies` — key-value map passed to `MapSimulationConfig`
- `corpus` — list of corpus file paths loaded by `YamlCorpusLoader`
- `capture` — list of event types to capture during simulation

The `ScenarioOrchestrator.activateSimulation()` method pushes a
`SimulationOverlay` onto the `SimulationRuntime` stack at scenario start
and pops it at scenario stop. This mechanism is unchanged.

## Testing

**Java:**
- ScenarioEnvelopeParser: envelope fields, chapters/sections/steps structure,
  raw step map extraction
- Speed default: omitted = no delay, explicit = pacing
- Actor inheritance: scenario-level default, step-level override
- Delay decorator on steps
- ForEach expansion through ScenarioCompiler with compact format
- When-conditional evaluation with compact format
- REST/GraphQL step maps: correct action-name-as-key shape
- Include expansion via IncludeExpander
- await validation: poll-retry rejected on mutations, response-check allowed
- Migrated YAML files parse through new parser
- onError handling: "stop" halts on first failure

**TS:**
- Wire protocol: `element` field in ScenarioCommand and CommandPayload
- `steps:` parsing in parseScenarioFromParsed (unchanged)
- Types consolidation

**Integration:**
- Scenario YAML → Java envelope parser → ScenarioCompiler (forEach, params,
  includes) → orchestrator dispatch → TS executor → Walker step resolution →
  browser execution

## Out of Scope

- Playbook naming unification (parked for post-epic)
- Multi-executor routing table (future, when distributed scenarios need it)
- TS-side Walker changes (already uses compact format)
- Orchestration primitives (barriers, channels, state machines — unchanged)
- Java-side Walker port (not needed — Java is a pass-through to TS executor)

## References

- `backend/scenario/src/main/java/.../HierarchicalParser.java` — bespoke 3-level parser (329 lines, being deleted)
- `backend/scenario/src/main/java/.../ScenarioCommand.java` — bespoke command record (being deleted)
- `backend/scenario/src/main/java/.../ScenarioParser.java` — Format A parser (being deleted)
- `backend/scenario/src/main/java/.../ScenarioStep.java` — sealed interface (being deleted)
- `backend/scenario/src/main/java/.../ScenarioCompiler.java` — forEach/includes pipeline (being adapted)
- `backend/scenario/src/main/java/.../ScenarioStepAdapter.java` — ForEachAdapter impl (being adapted)
- `backend/scenario-runtime/src/main/java/.../ScenarioOrchestrator.java` — serializes steps (wire protocol change)
- `backend/scenario-client/src/main/java/.../ScenarioAction.java` — existing handler annotation
- `packages/pages-aria/src/scenario/parser.ts` — TS parser (already uses Walker delegation)
- `packages/pages-aria/src/server/scenario-handler.ts:9-25` — ScenarioCommand + CommandPayload interfaces (target → element)
- `packages/pages-aria/src/scenario/types.ts` — TS types (consolidation)
- `packages/yaml-core/src/step/walker.ts` — Walker with REMOVED_KEYS, DECORATOR_KEYS
- `io.casehub.yaml.plugin.api.Plugin` — platform plugin annotation
- `io.casehub.yaml.plugin.api.Execute` — platform plugin execution annotation
- `io.casehub.yaml.plugin.api.Portability` — execution environment enum
- `engine/examples/yaml/sequential-onboarding.yaml` — engine do: blocks (established compact pattern)
- `META-INF/scenarios/helpdesk-intake.yaml` — commands[] format (migration target)
- `META-INF/scenarios/environment-setup.yaml` — commands[] with forEach (migration target)
- `META-INF/scenarios/onboard-team-members.yaml` — commands[] with forEach + when (migration target)
- `backend/scenario/src/test/resources/scenarios/helpdesk-demo.yaml` — already compact
- `backend/scenario/src/test/resources/scenarios/hybrid-helpdesk-demo.yaml` — already compact (REST/GraphQL ref update)
- Decisions D18–D26 in decisions.md (scope expansion rationale)
- Decisions D5–D12 in decisions.md (includes design)
- casehub-pages#390 (original issue — body needs scope update)
- casehub-pages#507 (closed — TS-side unification complete)
- casehubio/parent#409, casehubio/parent#408
