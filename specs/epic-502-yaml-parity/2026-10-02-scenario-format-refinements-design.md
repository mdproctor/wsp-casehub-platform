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
- Performs a thin structural transformation: identifies the action key (the
  single non-decorator key), extracts decorator sibling keys (`label:`,
  `step:`, `target:`, `actor:`, `delay:`, `when:`, `forEach:`), and
  produces a `CompactStep` record containing action name, params map,
  and decorator map
- No catalog resolution — step semantics are resolved at execution time
  on the executor side

**`CompactStep.java`** — record replacing `HierarchicalStep`. Fields:
action (String), params (Map), decorators (Map — label, step, target,
actor, delay, when, forEach, content, trigger, speed), temporal
(TemporalSpec).

**Step name derivation:** The wire protocol requires a `name` on every
dispatched step (the orchestrator uses names for completion tracking,
result storage, trigger resolution, and outline building). The name is
derived as: `decorator("step")` if present, otherwise
`slugify(decorator("label"))` (matching the current
`ScenarioStepAdapter.slugify()` — lowercase, non-alphanumeric replaced
with hyphens, leading/trailing hyphens stripped). Steps without either
`step:` or `label:` are rejected at parse time.

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
| `steps` | Flat step list (CompactStep records) | Top-level `steps:` array |

### What Gets Rewritten

**`ScenarioCompiler.java`** — complete rewrite of the glue code. The
platform-level infrastructure (`ForEachExpander`, `ForEachDirective`,
`CsvDataSource`, `VariableResolver`, `Truthiness`, `ParameterValidator`
from yaml-core) is format-agnostic and survives unchanged. Every piece of
pages-level glue that wires these to the step model is rewritten:

| Component | Current state | After rewrite |
|---|---|---|
| `compile()` entry point | Calls `HierarchicalParser.parse()` | Calls `ScenarioEnvelopeParser.parse()` |
| Step collection | `scenario.allSteps()` → `List<HierarchicalStep>` | `envelope.allSteps()` → `List<CompactStep>` |
| ForEach expansion | `ForEachExpander.expand(stepMap, ...)` with `ScenarioStepAdapter` | Same expansion, new `CompactStepAdapter` |
| Return type | `CompiledScenario(List<HierarchicalStep>)` | `CompiledScenario(List<CompactStep>)` |
| Call inlining | `inlineCalls()` constructs `HierarchicalStep` records | Rewritten to construct `CompactStep` records |
| Call detection | `step.commands().stream().filter(cmd → "call".equals(cmd.action()))` | `"call".equals(step.action())` |

**`ScenarioStepAdapter.java`** → **`CompactStepAdapter.java`** — rewritten:

| Method | Current | After rewrite |
|---|---|---|
| `stamp()` | Creates `HierarchicalStep` + resolved `ScenarioCommand` list | Creates `CompactStep` with resolved params map |
| `getForEach()` | `element.forEach()` (from HierarchicalStep field) | `step.decorator("forEach")` (from decorator map) |
| `getCondition()` | `element.when()` (from HierarchicalStep field) | `step.decorator("when")` (from decorator map) |
| Variable resolution | Iterates `ScenarioCommand` fields (`value`, `target`, `callParams`) | Iterates flat params map entries |

**`ScenarioExecutorClient.java`** — rewritten to consume the new wire
format. Currently receives `DispatchStep` with `commands[]` array and
iterates commands to invoke `@ScenarioAction` handlers:

| Concern | Current | After rewrite |
|---|---|---|
| Step shape | `stepNode.get("commands")` → iterate command array | Single action: `stepNode.get("action")` + `stepNode.get("params")` |
| Action dispatch | `cmdNode.path("action")` per command | `stepNode.path("action")` once per step |
| ActionContext data | `ActionContext.of(actor, data, awaitMatch)` from command `data` field | `ActionContext.of(actor, params, awaitMatch)` from step params map |
| Execution modes | `cmdNode.path("mode")` — SINGLE, BULK, STEPPED, STREAM | Step-level decorator: `stepNode.path("mode")` |
| Await handling | `cmdNode.get("await")` per command | `stepNode.get("await")` per step |
| Result aggregation | Last-write-wins across commands | Single action result per step |

The `@ScenarioAction` annotation and `ActionRegistry` are unchanged — they
still discover and route by action name. The change is in how the executor
client extracts the action name and builds `ActionContext` from the new
wire format.

**TS `scenario-handler.ts`** — `DispatchStep` interface and dispatch logic
rewritten:

| Interface | Current | After rewrite |
|---|---|---|
| `DispatchStep` | `{ name, label, actor?, commands: ScenarioCommand[] }` | `{ name, label, actor?, action, params, element? }` |
| `ScenarioCommand` | `{ action, target?, value?, data?, state?, timeout? }` | Removed — step IS the action |
| `CommandPayload` | `{ id, action, target?, value?, state?, timeout? }` | Adapted to read from step-level fields |

Dispatch logic changes from command-array iteration to single-action
execution per step.

### Plugin Taxonomy

Two plugin categories, using yaml-plugin-api:

| Category | Examples | Runtime | Executor routing |
|---|---|---|---|
| AriaStep | fill, click, navigate, spotlight, scroll-to-row | Browser DOM | Default → `browser` executor |
| ScenarioStep | show-markdown, callout, slide, rest, graphql | Presentation / Server | Explicit `target:` decorator required |

Registered through `@Plugin` annotation (from `io.casehub.yaml.plugin.api`).
Plugin `portability` field indicates execution environment (JAVA, TS, BOTH,
UNIVERSAL). Default routing inferred from portability; `target:` decorator
overrides per-step.

**Executor routing model:** Each step's `target:` decorator specifies which
executor receives the dispatch message. Executors register with the
`ExecutorRegistry` via `executor-register` messages, providing a name and
action list. The `SequencePartitioner` groups consecutive steps by target
for batched dispatch.

- AriaStep actions (fill, click, navigate, spotlight, etc.) default to
  `target: browser` — the browser executor (TS scenario-handler)
- REST/GraphQL steps must specify `target:` explicitly (e.g.,
  `target: server`) — the server-side executor (ScenarioExecutorClient)
- If `target:` is omitted, the default is `browser`
- The orchestrator validates all target executors are registered before
  dispatching

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
1. New envelope parser produces `CompactStep` records (action name + params)
2. Orchestrator serializes these for dispatch (new wire format)
3. Executor client routes to `@ScenarioAction` handlers using action name,
   building `ActionContext` from the step params map instead of command fields
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
  target: server

- step: inject-chat
  graphql:
    domain: connectors
    operation: injectChat
    params:
      platform: "slack"
      sender: "Alice"
      text: "My laptop won't boot"
  target: server

- step: verify-classified
  graphql:
    domain: engine
    operation: caseContext
    params:
      caseId: "${create-case.id}"
  target: server
  await:
    match:
      category: "HARDWARE"
    timeout: 30000
    interval: 500
```

The `step:` decorator names the step for result capture. Subsequent steps
reference results via `${stepName.field}` — e.g., `${create-case.id}`.

The `target: server` decorator routes these steps to the server-side
executor (`ScenarioExecutorClient`), which dispatches to `@ScenarioAction`
handlers for `rest` and `graphql` actions.

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

The platform-level infrastructure (`ForEachExpander`, `ForEachDirective`,
`CsvDataSource`, `VariableResolver`, `Truthiness` from yaml-core) is
format-agnostic and survives unchanged. The pages-level glue code
(ScenarioCompiler, ScenarioStepAdapter) is completely rewritten to work
with `CompactStep` instead of `HierarchicalStep` + `ScenarioCommand`.
See §What Gets Rewritten for the full scope.

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
  - file: seeds/create-user.yaml
    params:
      userName: "Alice"
      userRole: "Admin"
```

Include expansion happens as a pre-processing phase before step resolution
(D7 in decisions.md). The `IncludeExpander` loads templates via the `file:`
key, substitutes parameters via `VariableResolver`, and inlines the expanded
steps. Nested includes with cycle detection are supported (D10).

The `ScenarioCompiler.inlineCalls()` method is rewritten (not retained) as
part of the compiler rewrite — the call-inlining functionality is
reimplemented using `CompactStep` records instead of `HierarchicalStep`.
Existing `action: call` + `script:` YAML files are migrated to the
`includes:` format.

See decisions D5–D12 in decisions.md for full include design rationale.

### Wire Protocol Changes

The wire protocol between the Java orchestrator and executors changes from
a command-array format to a single-action-per-step format.

**Current wire format (being replaced):**
```json
{
  "name": "fill-subject",
  "label": "Fill ticket subject",
  "actor": "system",
  "commands": [
    {"action": "fill", "target": {"role": "textbox", "name": "Subject"}, "value": "..."}
  ]
}
```

**New wire format:**
```json
{
  "name": "fill-subject",
  "label": "Fill ticket subject",
  "actor": "system",
  "action": "fill",
  "element": {"role": "textbox", "name": "Subject"},
  "params": {"value": "Network connectivity issue"}
}
```

**Structural transformation (Java orchestrator):** The orchestrator performs
a thin structural transformation when serializing `CompactStep` for dispatch:

1. Emits step-level decorators: `name`, `label`, `actor`
2. Emits the action name: `action`
3. For ARIA steps: separates ARIA element fields (`role`, `name`, `index`,
   `within`) from the action params and nests them under `element`. The
   element field set is fixed: `{role, name, index, within}`.
4. Emits remaining params under `params`
5. Emits `await`, `mode` if present

**Non-ARIA step wire format (REST, GraphQL):**
```json
{
  "name": "create-case",
  "label": "Create case",
  "actor": "system",
  "action": "rest",
  "params": {"method": "POST", "url": "/api/cases", "body": {"subject": "..."}}
}
```

Non-ARIA steps have no `element` key — all action params go under `params`.

**TS interfaces updated:**
- `DispatchStep`: removes `commands[]`, adds `action`, `params`, `element?`
- `ScenarioCommand`: removed (step IS the action)
- `CommandPayload`: adapted to step-level fields
- `scenario-handler.ts`: dispatch logic rewritten from command-array
  iteration to single-action execution

### Semantic Constraints

**`await:` validation:** `await:` with `match:` is a **poll-based retry
pattern** — it re-invokes the operation on each poll cycle. This is only
safe on idempotent/query operations. Mutations must not be polled.

However, `await:` without `match:` (e.g., `await: { status: 201 }`) is
**response validation** — it checks the response of a single invocation.
This is safe on any operation, including mutations. The spec distinguishes:

| Pattern | Behavior | Allowed on mutations |
|---|---|---|
| `await: { match: {...}, timeout, interval }` | Poll-retry until match | No — rejected by executor at dispatch time |
| `await: { status: N }` | Single-invocation response check | Yes |

**Validation location:** Poll-retry mutation rejection happens at
**execution time in the executor** (`ScenarioExecutorClient`), not at
parse time. The executor knows its actions' semantics — REST POST/PUT/DELETE
are mutations, REST GET is idempotent; GraphQL operations are classified by
their schema type (query vs. mutation). The envelope parser and compiler
have no catalog access and cannot classify actions.

**Result aggregation:** Each step is a single action in the compact format.
Multi-action grouping (via `block:`) follows standard Walker semantics.
Last-write-wins merge for block results. Intra-step variable references
(`${thisStep.field}`) prohibited. Compose via sequential steps with variable
references instead.

### Walker DECORATOR_KEYS Extension

The unified format uses decorator sibling keys on steps (`label:`,
`target:`, `actor:`, `when:`, `speed:`, `content:`) that the Walker does
not currently recognize. The Walker's `resolveOne()` in `walker.ts` treats
any key not in `DECORATOR_KEYS` or `RESERVED_KEYS` as a potential action
key — if absent from the catalog, it throws `"unknown step key"`. This
blocks all client-side scenario loading through `parseScenario()` /
`parseScenarioWithIncludes()` since those call `Walker.resolve()` on the
raw step arrays.

**Fix:** Add scenario decorator keys to Walker's `DECORATOR_KEYS` and
`RESERVED_KEYS` sets:

| Key | Purpose | Currently in Walker? |
|---|---|---|
| `label` | Step display name | No → add to DECORATOR_KEYS + RESERVED_KEYS |
| `target` | Executor routing | No → add to DECORATOR_KEYS + RESERVED_KEYS |
| `actor` | Authentication identity | No → add to DECORATOR_KEYS + RESERVED_KEYS |
| `when` | Conditional execution (Truthiness) | No → add to DECORATOR_KEYS + RESERVED_KEYS |
| `speed` | Per-step pacing override | No → add to DECORATOR_KEYS + RESERVED_KEYS |
| `content` | Narrative content | No → add to DECORATOR_KEYS + RESERVED_KEYS |

These keys are general-purpose step metadata. The Walker already carries
domain-specific decorators (`signal`, `publish`, `semaphore`, `barrier`,
`quorum`, `race`) through without interpretation — adding scenario-specific
decorators is consistent with this pattern. The Walker stores them in the
`decorators` map on `ResolvedStep`; the scenario execution layer reads
them after resolution.

**Semantic note on `when` vs. `if`:** The Walker already uses `if` for
structural branching (`if: condition` with `then:`/`else:` blocks). `when`
is a different mechanism — Truthiness-based conditional filtering used by
forEach expansion. They coexist: `if` is structural control flow (Walker-
interpreted), `when` is a decorator (Walker-carried, evaluated by the
scenario compiler or execution layer).

**`parser.ts` `preExtract()` — no change needed:** Once the keys are in
DECORATOR_KEYS, the Walker handles them directly. The `preExtract()`
function does not need to strip or re-attach them.

### TS Changes

- `parseScenarioFromParsed()` — already reads `steps:` (no rename needed)
- Walker `DECORATOR_KEYS` / `RESERVED_KEYS`: add `label`, `target`,
  `actor`, `when`, `speed`, `content`
- `DispatchStep` interface: `commands[]` removed, `action` + `params` +
  `element?` added
- `ScenarioCommand` interface: removed
- `CommandPayload` interface: adapted to step-level fields
- `scenario-handler.ts`: dispatch rewritten for single-action-per-step
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
- `hybrid-helpdesk-demo.yaml` — already compact format (`delivery:` sibling
  replaced with `target: server` decorator; REST/GraphQL params use
  action-name-as-key)
- `caller-script.yaml` — `action: call` migrated to `includes:` format
- `callee-create-user.yaml` — parameterized callee (becomes include template)
- `foreach-csv-inline.yaml` — forEach + when with CSV data → compact
- `parameterized-onboard.yaml` — parameterized steps → compact
- `cyclic-a.yaml`, `cyclic-b.yaml` — cycle detection tests → compact
- `environment-setup.yaml` (test copy) → compact

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
  CompactStep extraction
- Speed default: omitted = no delay, explicit = pacing
- Actor inheritance: scenario-level default, step-level override
- Delay decorator on steps
- ForEach expansion through ScenarioCompiler with CompactStep
- When-conditional evaluation with CompactStep
- REST/GraphQL step maps: correct action-name-as-key shape with target: server
- Include expansion via IncludeExpander (using `file:` key)
- ScenarioExecutorClient: single-action dispatch, ActionContext from params map
- Migrated YAML files parse through new parser
- onError handling: "stop" halts on first failure

**TS:**
- Walker DECORATOR_KEYS: `label`, `target`, `actor`, `when`, `speed`,
  `content` carried through as decorators on ResolvedStep
- Walker: existing tests still pass (no structural changes)
- Wire protocol: new DispatchStep shape (action + params + element?)
- `steps:` parsing in parseScenarioFromParsed (unchanged)
- scenario-handler.ts: single-action dispatch logic
- Types consolidation

**Integration:**
- Server-dispatched: Scenario YAML → Java envelope parser → ScenarioCompiler
  (forEach, params, includes) → orchestrator serialization → executor dispatch →
  (browser: scenario-handler → executeAriaCommand → DOM) |
  (server: ScenarioExecutorClient → @ScenarioAction handler)
- Client-loaded: Scenario YAML → TS parseScenario() → Walker.resolve() →
  ResolvedStep[] with decorators → scenario execution

## Out of Scope

- Playbook naming unification (parked for post-epic)
- Multi-executor routing table (future, when distributed scenarios need it)
- Orchestration primitives (barriers, channels, state machines — unchanged)
- Java-side Walker port (not needed — step resolution on TS executor side)
- `@ScenarioAction` → `@Plugin` convergence (future, post-format-convergence)
- Walker structural changes (control flow, resolution logic — unchanged;
  only DECORATOR_KEYS/RESERVED_KEYS sets extended)

## Decisions revised during review

Decisions D18–D26 in decisions.md record the pre-review design. The
following were revised during adversarial design review:

- **D19** originally specified three plugin categories including
  ScenarioStructure. Revised: two categories (AriaStep, ScenarioStep).
  Chapters/sections are structural containers, not plugins.
- **D24** originally stated "All step types are plugins" including
  ScenarioStructure. Revised: structural containers are excluded.
- **D25** originally described delegation to the Walker/plugin catalog and
  used `do:` blocks. Revised: Java side performs a thin structural
  transformation (not catalog resolution), uses `steps:` (not `do:`).
- **Out of Scope** originally listed "TS-side Walker changes" as out of
  scope. Revised: Walker DECORATOR_KEYS/RESERVED_KEYS must be extended
  with scenario decorator keys (`label`, `target`, `actor`, `when`,
  `speed`, `content`) — without this, client-side scenario loading fails.

## References

- `backend/scenario/src/main/java/.../HierarchicalParser.java` — bespoke 3-level parser (329 lines, being deleted)
- `backend/scenario/src/main/java/.../ScenarioCommand.java` — bespoke command record (being deleted)
- `backend/scenario/src/main/java/.../ScenarioParser.java` — Format A parser (being deleted)
- `backend/scenario/src/main/java/.../ScenarioStep.java` — sealed interface (being deleted)
- `backend/scenario/src/main/java/.../ScenarioCompiler.java` — forEach/includes pipeline (being rewritten)
- `backend/scenario/src/main/java/.../ScenarioStepAdapter.java` — ForEachAdapter impl (being rewritten as CompactStepAdapter)
- `backend/scenario/src/main/java/.../IncludeExpander.java` — include expansion (file: key, TemplateLoader SPI)
- `backend/scenario-runtime/src/main/java/.../ScenarioOrchestrator.java` — serializes steps (wire protocol rewrite)
- `backend/scenario-runtime/src/main/java/.../SequencePartitioner.java` — groups steps by target (type change: HierarchicalStep → CompactStep)
- `backend/scenario-runtime/src/main/java/.../ExecutorRegistry.java` — executor name → connection map (unchanged)
- `backend/scenario-client/src/main/java/.../ScenarioExecutorClient.java` — dispatch-sequence consumer (being rewritten)
- `backend/scenario-client/src/main/java/.../ActionRegistry.java` — @ScenarioAction handler discovery (unchanged)
- `backend/scenario-client/src/main/java/.../ActionContext.java` — handler context interface (unchanged)
- `backend/scenario-client/src/main/java/.../ScenarioAction.java` — existing handler annotation (unchanged)
- `packages/pages-aria/src/scenario/parser.ts` — TS parser (already uses Walker delegation)
- `packages/pages-aria/src/server/scenario-handler.ts` — TS dispatch (DispatchStep rewrite, ScenarioCommand removal)
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
- `backend/scenario/src/test/resources/scenarios/hybrid-helpdesk-demo.yaml` — already compact (routing update)
- Decisions D18–D26 in decisions.md (scope expansion rationale; D19/D24/D25 revised during review)
- Decisions D5–D12 in decisions.md (includes design)
- casehub-pages#390 (original issue — body needs scope update)
- casehub-pages#507 (closed — TS-side unification complete)
- casehubio/parent#409, casehubio/parent#408
