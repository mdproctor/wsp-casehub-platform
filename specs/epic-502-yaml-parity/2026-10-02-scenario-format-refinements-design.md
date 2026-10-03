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
- Decorators as sibling keys (see §Canonical Decorator Keys for the full
  set): `label:`, `step:` (naming), `target:` (executor), `actor:`,
  `delay:`, `when:`, `speed:`, `forEach:`, `await:`, `mode:`
- Speed omitted = no inter-step delay (opt-in pacing via explicit `speed:`).
  Executors guard: `if (speed <= 0 || speed >= 1000)` skip delay entirely —
  speed ≤ 0 is the sentinel for "no pacing"
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
  single non-decorator key), extracts all decorator sibling keys (see
  §Canonical Decorator Keys for the complete set), and produces a
  `CompactStep` record containing action name, params map, and decorator
  map
- **Applies defaults:** If a step has no `target:` decorator, the parser
  sets `target: "browser"`. If a step has no `actor:` decorator but the
  envelope has a scenario-level `actor:`, the parser propagates the
  scenario-level actor to the step. **Invariants after parsing:**
  `CompactStep.decorator("target")` is never null;
  `CompactStep.decorator("actor")` is never null when the envelope
  declares a scenario-level actor
- No catalog resolution — step semantics are resolved at execution time
  on the executor side

**`CompactStep.java`** — record replacing `HierarchicalStep`. Fields:
action (String), params (Map), forEach (ForEachDirective — nullable),
trigger (Trigger — nullable), temporal (TemporalSpec — nullable),
decorators (Map — see §Canonical Decorator Keys).

**Boundary principle:** Typed fields for data with parser-validated
polymorphic shape — `forEach` (sealed: GroupRef | InlineIteration),
`trigger` (sealed: AfterTrigger | TimeTrigger | DataTrigger), and
`temporal` (structured with action enum and events list). The decorator
map carries simple values (strings, numbers) that the parser passes
through without structural validation. `action` and `params` are typed
because they are the step's essential identity.

#### Canonical Decorator Keys

All decorator keys recognized by CompactStep, the envelope parser, and
the Walker (where applicable). This is the single authoritative list —
all sections of this spec reference it.

| Key | Purpose | CompactStep | Walker |
|---|---|---|---|
| `label` | Step display name | decorator | add to DECORATOR_KEYS |
| `step` | Step identifier (result capture, triggers) | decorator | already in RESERVED_KEYS |
| `target` | Executor routing (browser, server) | decorator | add to DECORATOR_KEYS |
| `actor` | Authentication identity | decorator | add to DECORATOR_KEYS |
| `delay` | Per-step delay before execution | decorator | already in DECORATOR_KEYS |
| `when` | Conditional execution (Truthiness filter) | decorator | add to DECORATOR_KEYS |
| `forEach` | Data-driven expansion directive | **typed field** (ForEachDirective) | already in DECORATOR_KEYS |
| `content` | Narrative/spotlight content (step-level only — see §Content Key Disambiguation) | decorator | add to DECORATOR_KEYS |
| `trigger` | Step trigger specification | **typed field** (Trigger) | already in DECORATOR_KEYS |
| `speed` | Per-step pacing override | decorator | add to DECORATOR_KEYS |
| `await` | Polling/validation specification (see §Semantic Constraints) | decorator | add to DECORATOR_KEYS |
| `mode` | Execution mode (SINGLE, BULK, STEPPED, STREAM) | decorator | add to DECORATOR_KEYS |

`await` and `mode` migrate from `ScenarioCommand` fields to CompactStep
decorators. In the current code, `ScenarioCommand.await()` is an
`AwaitCondition` record (match, timeout, interval) and
`ScenarioCommand.mode()` is a `DataMode` enum. In CompactStep, they
become entries in the decorators map — `await` as a Map, `mode` as a
String. The executor client reads them from the step-level wire format
(`stepNode.get("await")`, `stepNode.path("mode")`), consistent with the
rewrite table in §What Gets Rewritten.

#### TemporalSpec

`TemporalSpec` is an existing record from the scenario module
(`io.casehub.pages.scenario.TemporalSpec`), carried forward unchanged
from `HierarchicalStep`. It controls temporal simulation drivers and has
fields: `action` (enum: START, STOP, PAUSE, RESUME, SET_SPEED), `name`,
`profile`, `qualifiedName`, `tenancyId`, `events` (List of
delay/label/payload records), `loop` (Boolean), `speed` (Double). Steps
with `temporal` set are dispatched to `TemporalDriverService`, not to an
executor — they have no `target` requirement.

#### Content Key Disambiguation

The `content:` key appears at two structural levels with distinct
purposes:

- **Section-level:** `sections: [{ label: "...", content: "Walk through
  the form", steps: [...] }]` — narrative description of the section,
  parsed by the envelope parser as a field of the section container. This
  is structural metadata, not a decorator.
- **Step-level:** `spotlight: { ... } content: "Priority drives SLA
  timers"` — narrative text for spotlight overlays, carried as a decorator
  on CompactStep / ResolvedStep.

There is no syntactic ambiguity: the envelope parser knows whether it is
reading a section object or a step object. Section `content:` is a field
on the section container; step `content:` is a decorator sibling key
extracted alongside the action.

**Step name derivation:** The wire protocol requires a `name` on every
dispatched step (the orchestrator uses names for completion tracking,
result storage, trigger resolution, and outline building). The name is
derived as:
1. `decorator("step")` if present (explicit programmatic name)
2. Otherwise `slugify(decorator("label"))` if `label:` is present
   (matching the current `ScenarioStepAdapter.slugify()` — lowercase,
   non-alphanumeric replaced with hyphens, leading/trailing hyphens
   stripped)
3. Otherwise auto-derived as `{action}-{sequentialIndex}` where
   `sequentialIndex` is the step's zero-based position in the
   flattened step list (e.g., `navigate-0`, `fill-1`, `click-2`)

Auto-derivation ensures existing YAML files without `step:` or `label:`
decorators parse successfully. Only steps that need to be referenced in
variable interpolation (`${stepName.field}`) require explicit `step:`
names.

**Step name uniqueness:** The envelope parser validates that all derived
names (from any derivation path above) are unique across all steps in
the scenario. If a collision is detected, the parser fails fast with an
error identifying the conflicting names and their source labels. This
prevents silent overwrite in the compiler's `stepMap`.

**TS path step name derivation:** The step name derivation logic above
applies to the **Java envelope parser**. On the TS Walker path, `step:`
is handled as a RESERVED_KEY (sets `ResolvedStep.name` directly), while
`label:` is a DECORATOR_KEY (stored in `ResolvedStep.decorators.label`).
The Walker does NOT derive names from labels — this is correct, as the
Walker is a step resolution tool, not a name derivation tool. The TS
scenario execution layer (downstream of `parseScenarioFromParsed()`)
must derive step names from `decorators.label` when `ResolvedStep.name`
is null, using the same `slugify()` logic. For server-dispatched
scenarios, this is handled by the Java orchestrator before dispatch; for
client-loaded scenarios, the TS execution layer must apply the same
derivation.

**`ScenarioEnvelope.java`** — record holding parsed envelope + structure.
Replaces HierarchicalScenario. Fields:

| Field | Description | Source |
|---|---|---|
| `scenario` | Scenario name (required) | Top-level `scenario:` key |
| `description` | Human-readable description | Top-level or `meta.description` |
| `speed` | Inter-step delay multiplier. Omitted = no delay (speed ≤ 0 sentinel). Both executors guard: `if (speed <= 0 \|\| speed >= 1000) return` before computing delay | Top-level `speed:` |
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
| Call inlining | `inlineCalls()` + `CallGraphValidator` | Deleted — `IncludeExpander` replaces call-inlining (see §Scenario Includes) |

**`ScenarioStepAdapter.java`** → **`CompactStepAdapter.java`** — rewritten:

| Method | Current | After rewrite |
|---|---|---|
| `stamp()` | Creates `HierarchicalStep` + resolved `ScenarioCommand` list | Creates `CompactStep` with resolved params map |
| `getForEach()` | `element.forEach()` (from HierarchicalStep field) | `step.forEach()` (typed field) |
| `getCondition()` | `element.when()` (from HierarchicalStep field) | `step.decorator("when")` (from decorator map) |
| Variable resolution | Iterates `ScenarioCommand` fields (`value`, `target`, `callParams`) | Iterates flat params map entries |

**`ScenarioOrchestrator.java`** — type-change pass across all
responsibilities. The orchestrator (590 lines) references
`HierarchicalParser`, `HierarchicalScenario`, `HierarchicalStep`,
`ScenarioCommand`, and `AriaTarget`. Wire serialization is fully
rewritten (see §Wire Protocol Changes); the remaining responsibilities
are mechanical type migrations:

| Responsibility | Current type dependency | After rewrite |
|---|---|---|
| Parsing | `HierarchicalParser.parse(yaml)` → `HierarchicalScenario` | `ScenarioEnvelopeParser.parse(yaml)` → `ScenarioEnvelope` |
| Step list | `scenario.allSteps()` → `List<HierarchicalStep>` | `envelope.allSteps()` → `List<CompactStep>` |
| Step completion tracking | `step.name()` / `step.label()` | `step.decorator("step")` / `step.decorator("label")` (or step name derivation) |
| Outline building | `step.commands().get(0).action()` | `step.action()` |
| Narrative content | `step.content()` → `NarrativeContent` | `step.decorator("content")` → wrap as `NarrativeContent.Inline` |
| Executor validation | `HierarchicalStep::target` | `step.decorator("target")` (never null — parser invariant) |
| Temporal handling | `step.temporal()` | `step.temporal()` (typed field, unchanged) |
| Trigger dispatch | `step.trigger() instanceof Trigger.AfterTrigger` | `step.trigger() instanceof Trigger.AfterTrigger` (typed field, unchanged) |
| Run-to navigation | `step.label()` | `step.decorator("label")` |
| Serialization | `ScenarioCommand`, `AriaTarget` → commands[] JSON | `step.action()`, `step.params()` → flat JSON (see §Wire Protocol) |

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

**Control handling:** The `handleControl` switch must add `case "stop"`:
clears step queue, aborts in-progress execution, and sends a failure
result for each uncompleted step. The `sleepForSpeed()` method must
guard: `if (speed <= 0 || speed >= 1000) return;` before computing delay.

**TS `scenario-handler.ts`** — `DispatchStep` interface and dispatch logic
rewritten:

| Interface | Current | After rewrite |
|---|---|---|
| `DispatchStep` | `{ name, label, actor?, commands: ScenarioCommand[] }` | `{ name, label, actor?, action, params }` |
| `ScenarioCommand` | `{ action, target?, value?, data?, state?, timeout? }` | Removed — step IS the action |
| `CommandPayload` | `{ id, action, target?, value?, state?, timeout? }` | Adapted to read from step-level fields |

Dispatch logic changes from command-array iteration to single-action
execution per step. ARIA actions reconstruct `AriaTarget` from flat
params (`{role, name, index, within}`) at execution time.

**TS control handling:** The `onControl` switch must add `case 'stop'`:
sets a `stopped` flag, clears `stepQueue`, sends failure results for
pending steps. The speed delay guard must also be added:
`if (speed <= 0 || speed >= 1000)` skip delay.

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

**Parser path boundary:** The unified YAML format means one syntax, not
one parser path. The format is the same regardless of which parser
processes the file:

- **Server-dispatched scenarios** (containing any combination of ARIA,
  REST, GraphQL steps) go through the **Java envelope parser** →
  ScenarioCompiler → ScenarioOrchestrator → dispatch to executors.
  The envelope parser has no catalog — it passes action names through
  without resolution.
- **Client-loaded scenarios** (ARIA-only, loaded via TS
  `parseScenario()`) go through the **TS Walker** → catalog resolution
  → `ResolvedStep[]`. The Walker resolves action keys against the TS
  step catalog.

Server-side action keys (`rest`, `graphql`) are NOT registered in the
TS step catalog. A unified-format file containing these steps must not
be loaded through the TS Walker path — the Walker would throw "unknown
step key." This is architecturally correct: the TS Walker resolves steps
for browser execution; server-side steps are dispatched by the Java
orchestrator to server-side executors. Scenario files that mix ARIA and
REST/GraphQL steps are always server-dispatched (the Java orchestrator
routes each step to the appropriate executor by `target:` decorator).

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

Existing `action: call` + `script:` YAML files are migrated to the
`includes:` format. With this migration complete, the
`ScenarioCompiler.inlineCalls()` method and `CallGraphValidator` are
**deleted** — they have no callers once all call-based YAML files use
`includes:`. The `IncludeExpander` fully replaces the call-inlining
functionality: both are compile-time operations that inline external
steps, but `includes:` operates at the YAML structure level (pre-parse)
while `inlineCalls()` operated on parsed `HierarchicalStep` records
(post-parse). The pre-parse approach is cleaner — it composes with all
downstream processing (forEach expansion, when-conditionals) without
needing to understand the step model.

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
  "params": {"role": "textbox", "name": "Subject", "value": "Network connectivity issue"}
}
```

**Structural transformation (Java orchestrator):** The orchestrator performs
a thin, uniform transformation when serializing `CompactStep` for dispatch:

1. Emits step-level decorators: `name`, `label`, `actor`
2. Emits the action name: `action`
3. Emits **all** action params flat under `params` — no element extraction
4. Emits `await`, `mode` if present

The orchestrator has no step-type knowledge — it does not distinguish
ARIA steps from REST/GraphQL steps. All params are passed through flat.
Step semantics (including AriaTarget reconstruction from `{role, name,
index, within}` params) are resolved at **execution time on the executor
side**, consistent with the "no catalog resolution" principle.

**REST/GraphQL wire format (identical structure):**
```json
{
  "name": "create-case",
  "label": "Create case",
  "actor": "system",
  "action": "rest",
  "params": {"method": "POST", "url": "/api/cases", "body": {"subject": "..."}}
}
```

All steps use the same flat `params` structure regardless of action type.

**Orchestrator callback guard:** The `onStepResult` completion check
(`completedSteps.size() == allSteps.size()`) must be guarded with an
`AtomicBoolean callbackFired` to prevent double callback invocation
from concurrent executor threads completing the last steps
simultaneously. The guard is `callbackFired.compareAndSet(false, true)`
before `fireCallback`.

**TS interfaces updated:**
- `DispatchStep`: removes `commands[]`, adds `action`, `params`
  (flat map — no `element` field)
- `ScenarioCommand`: removed (step IS the action)
- `CommandPayload`: adapted to step-level fields
- `scenario-handler.ts`: dispatch logic rewritten from command-array
  iteration to single-action execution. ARIA actions reconstruct
  `AriaTarget` from flat params: `{role, name, index, within}` extracted
  from `params` at execution time
- `ExecutorControl` type: add `'stop'` to command union

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

The unified format uses decorator sibling keys on steps that the Walker
does not currently recognize (see §Canonical Decorator Keys for the full
set). The Walker's `resolveOne()` in `walker.ts` treats any key not in
`DECORATOR_KEYS` or `RESERVED_KEYS` as a potential action key — if absent
from the catalog, it throws `"unknown step key"`. This blocks all
client-side scenario loading through `parseScenario()` /
`parseScenarioWithIncludes()` since those call `Walker.resolve()` on the
raw step arrays.

**Fix:** Add scenario decorator keys to Walker's `DECORATOR_KEYS` and
`RESERVED_KEYS` sets. The canonical table (§Canonical Decorator Keys)
lists which keys need adding. Summary of additions:

| Key | Purpose | Currently in Walker? |
|---|---|---|
| `label` | Step display name | No → add to DECORATOR_KEYS + RESERVED_KEYS |
| `target` | Executor routing | No → add to DECORATOR_KEYS + RESERVED_KEYS |
| `actor` | Authentication identity | No → add to DECORATOR_KEYS + RESERVED_KEYS |
| `when` | Conditional execution (Truthiness) | No → add to DECORATOR_KEYS + RESERVED_KEYS |
| `speed` | Per-step pacing override | No → add to DECORATOR_KEYS + RESERVED_KEYS |
| `content` | Narrative content | No → add to DECORATOR_KEYS + RESERVED_KEYS |
| `await` | Polling/validation specification | No → add to DECORATOR_KEYS + RESERVED_KEYS |
| `mode` | Execution mode | No → add to DECORATOR_KEYS + RESERVED_KEYS |

Note: `delay`, `forEach`, and `trigger` are already in Walker
DECORATOR_KEYS. `step` is already in RESERVED_KEYS.

These are scenario-specific decorators needed by the TS Walker because
it processes both engine steps and client-loaded scenario steps (via
`parseScenario()` → `Walker.resolve()`). The Walker already carries
domain-specific decorators (`signal`, `publish`, `semaphore`, `barrier`,
`quorum`, `race`) through without interpretation — adding scenario
decorators is consistent with this pattern. The Walker stores them in
the `decorators` map on `ResolvedStep`; the scenario execution layer
reads them after resolution.

**Java StepWalker — intentionally not updated:** The Java `StepWalker`
(in yaml-step-runtime) processes engine `do:` blocks only. Scenario
YAML bypasses the Java Walker entirely — the Java envelope parser reads
steps as raw maps without catalog resolution (D25). Adding scenario
decorators to the Java Walker would add dead recognition for keys that
never appear in engine steps. The key sets are intentionally asymmetric:
the TS Walker needs these keys because it handles scenarios; the Java
Walker does not because it handles only engine steps.

**Semantic note on `when` vs. `if`:** The Walker already uses `if` for
structural branching (`if: condition` with `then:`/`else:` blocks). `when`
is a different mechanism — Truthiness-based conditional filtering used by
forEach expansion. They coexist: `if` is structural control flow (Walker-
interpreted), `when` is a decorator (Walker-carried, evaluated by the
scenario compiler or execution layer).

**`parser.ts` `WALKER_KNOWN_KEYS` — must be updated:** The
`WALKER_KNOWN_KEYS` set in `parser.ts` is a local duplicate of the
Walker's `RESERVED_KEYS`. It must be extended with `label`, `target`,
`actor`, `when`, `speed`, `content`, `await`, `mode` to match. Without
this update, the `hasActionKey()` function treats the new decorator keys
as action keys, breaking pre-extraction for signal-fire, barrier-await,
and signal-await steps that carry any of these decorators.
`preExtract()` itself needs no structural changes — only its dependency
on `WALKER_KNOWN_KEYS` is affected. Note: `preExtract()` already handles
`await` explicitly for signal/barrier patterns; adding `await` to
`WALKER_KNOWN_KEYS` ensures that non-signal/barrier `await:` decorators
(e.g., `await: { match: ... }`) are also correctly excluded from
action-key detection.

### TS Changes

- `parseScenarioFromParsed()` — already reads `steps:` (no rename needed).
  **Section parsing:** `sec['title']` → `sec['label']` to match the
  unified format. `TutorialSection.title` → `TutorialSection.label`
- Walker `DECORATOR_KEYS` / `RESERVED_KEYS`: add `label`, `target`,
  `actor`, `when`, `speed`, `content`, `await`, `mode` (see §Canonical
  Decorator Keys)
- `parser.ts` `WALKER_KNOWN_KEYS`: add `label`, `target`, `actor`,
  `when`, `speed`, `content`, `await`, `mode` to match Walker update
- `DispatchStep` interface: `commands[]` removed, `action` + `params`
  added (flat params — no `element` field)
- `ScenarioCommand` interface: removed
- `CommandPayload` interface: adapted to step-level fields
- `scenario-handler.ts`: dispatch rewritten for single-action-per-step.
  ARIA actions reconstruct `AriaTarget` from flat params at execution
  time. `executeAriaCommand` builds `AriaTarget` from
  `{role, name, index, within}` in the params map
- `scenario-handler.ts`: `onControl` switch: add `case 'stop'` —
  clears step queue, aborts in-progress execution, sends results for
  uncompleted steps
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
- Speed default: omitted = no delay, explicit = pacing. Speed ≤ 0 guard
  in `sleepForSpeed()` — verify no delay computed
- Actor inheritance: scenario-level default propagated to steps, step-level
  override
- Target defaulting: omitted target → `"browser"` (parser invariant)
- Step name derivation: explicit `step:` → slugified `label:` → auto-derived
  `{action}-{index}`. Uniqueness validation on collision
- Delay decorator on steps
- ForEach expansion through ScenarioCompiler with CompactStep
- When-conditional evaluation with CompactStep
- REST/GraphQL step maps: correct action-name-as-key shape with target: server
- Include expansion via IncludeExpander (using `file:` key)
- ScenarioExecutorClient: single-action dispatch, ActionContext from params map
- ScenarioExecutorClient: `await` decorator read from step-level wire format,
  poll-retry logic preserved from command-level
- ScenarioExecutorClient: `mode` decorator (SINGLE/BULK/STEPPED/STREAM) read
  from step-level wire format
- ScenarioExecutorClient: `case "stop"` clears queue, aborts, sends failure
  results
- Orchestrator `onStepResult`: `AtomicBoolean callbackFired` guard prevents
  double callback from concurrent threads
- Migrated YAML files parse through new parser
- onError handling: "stop" halts on first failure

**TS:**
- Walker DECORATOR_KEYS: `label`, `target`, `actor`, `when`, `speed`,
  `content`, `await`, `mode` carried through as decorators on ResolvedStep
- Walker: existing tests still pass (no structural changes)
- `parser.ts` WALKER_KNOWN_KEYS: updated with new decorator keys
- Wire protocol: new DispatchStep shape (action + params, flat — no element)
- `steps:` parsing in parseScenarioFromParsed — section field:
  `sec['label']` (not `sec['title']`)
- scenario-handler.ts: single-action dispatch logic with AriaTarget
  reconstruction from flat params
- scenario-handler.ts: `case 'stop'` in onControl clears queue
- scenario-handler.ts: speed ≤ 0 guard before delay computation
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
  with scenario decorator keys (see §Canonical Decorator Keys: `label`,
  `target`, `actor`, `when`, `speed`, `content`, `await`, `mode`) —
  without this, client-side scenario loading fails.

## References

- `backend/scenario/src/main/java/.../HierarchicalParser.java` — bespoke 3-level parser (329 lines, being deleted)
- `backend/scenario/src/main/java/.../ScenarioCommand.java` — bespoke command record (being deleted)
- `backend/scenario/src/main/java/.../ScenarioParser.java` — Format A parser (being deleted)
- `backend/scenario/src/main/java/.../ScenarioStep.java` — sealed interface (being deleted)
- `backend/scenario/src/main/java/.../ScenarioCompiler.java` — forEach/includes pipeline (being rewritten)
- `backend/scenario/src/main/java/.../ScenarioStepAdapter.java` — ForEachAdapter impl (being rewritten as CompactStepAdapter)
- `backend/scenario/src/main/java/.../IncludeExpander.java` — include expansion (file: key, TemplateLoader SPI)
- `backend/scenario-runtime/src/main/java/.../ScenarioOrchestrator.java` — type-change pass + wire protocol rewrite (see §What Gets Rewritten)
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
