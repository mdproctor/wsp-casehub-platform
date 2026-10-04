# Scenario Lifecycle State — Design Spec

**Issue:** casehub-pages#498
**Date:** 2026-10-04
**Branch:** epic-502-yaml-parity

## Summary

Add lifecycle state to scenarios: DRAFT, ACTIVE, ARCHIVED. Uploaded scripts start as DRAFT. Bundled and external scripts are implicitly ACTIVE. OrcStateMachine enforces valid transitions. CDI events fire on transitions.

Versioning is git's job — not addressed here. Durable approval workflows belong in Serverless Workflow (casehub-pages#517) — not addressed here.

## Data Model

### ScriptLifecycleState

New enum in `io.casehub.pages.scenario`:

```java
public enum ScriptLifecycleState { DRAFT, ACTIVE, ARCHIVED }
```

- **DRAFT** — authored/edited, testable in simulation, not executable in production
- **ACTIVE** — available for event-triggered or manual execution
- **ARCHIVED** — retained for history/audit, not executable (terminal)

### ScriptDescriptor

Gains a `state` field:

```java
public record ScriptDescriptor(String name, String description,
    List<String> labels, List<String> tags,
    List<ParamDescriptor> params, List<String> calls,
    ScriptProvenance provenance,
    ScriptLifecycleState state,
    List<AriaTarget> firstStepTargets)
```

Compact constructor defaults `state` to `ACTIVE` when null (backward compatibility). `ScriptDescriptorExtractor.extract()` passes `DRAFT` for uploaded provenance, `ACTIVE` for bundled/external.

### TypeScript Mirror

`ScriptDescriptor` interface in `library-view.ts` gains `state: string`.

## State Machine

OrcStateMachine from yaml-core enforces transitions, following the TemporalSimulationDriver lifecycle precedent.

### Valid Transitions

```
DRAFT ──→ ACTIVE ──→ ARCHIVED
             │
             └──→ DRAFT (revise)
```

- DRAFT → ACTIVE (activate)
- ACTIVE → ARCHIVED (archive)
- ACTIVE → DRAFT (revise)
- ARCHIVED is terminal

### Implementation

`UploadedScriptSource` holds a `Map<String, OrcStateMachine<ScriptLifecycleState>>` — one per uploaded script. Created on upload, rebuilt on startup scan.

```java
var sm = DefaultOrcStateMachine.<ScriptLifecycleState>builder(
        "script:" + name, ScriptLifecycleState.class, DRAFT)
    .transition(DRAFT, ACTIVE)
    .transition(ACTIVE, ARCHIVED)
    .transition(ACTIVE, DRAFT)
    .build();
```

### Registry Methods

`ScriptRegistry` gains:

- `activate(String name)` — DRAFT → ACTIVE
- `archive(String name)` — ACTIVE → ARCHIVED
- `revise(String name)` — ACTIVE → DRAFT

All throw `IllegalStateException` on invalid transitions. All throw `IllegalArgumentException` for non-uploaded scripts.

## CDI Events

Fired via `onTransition` handlers, from `ScriptRegistry`:

- `ScriptActivated(String name, ScriptDescriptor descriptor)`
- `ScriptArchived(String name, ScriptDescriptor descriptor)`
- `ScriptRevised(String name, ScriptDescriptor descriptor)`

Records in `io.casehub.pages.scenario`. These enable #499 (event-triggered activation) to observe lifecycle changes.

## Execution Filtering

`ScriptRegistry` gains `listActive(List<String> labels, List<String> tags)` — filters to `state == ACTIVE`. The scenario orchestrator uses `listActive()` for execution queries. Existing `list()` remains unfiltered for the library UI.

## Scope Boundaries

**In scope:** state enum, state field on descriptor, OrcStateMachine transitions, CDI events, active filtering.

**Out of scope:**
- Application-level versioning — git handles content history
- Approval workflow / SPI — casehub-pages#517 (Serverless Workflow)
- Persistence of lifecycle state — volatile, in-memory
- Git-backed script storage — separate concern, separate issue
- REST/GraphQL lifecycle endpoints — not needed yet
- Lifecycle for bundled/external scripts — implicitly ACTIVE

## References

- ScriptDescriptor.java — data model being extended
- UploadedScriptSource.java — mutable source gaining state machines
- OrcStateMachine.java, DefaultOrcStateMachine.java — state machine primitives
- TemporalSimulationDriver.java — OrcStateMachine lifecycle precedent
- casehub-pages#498 — source issue
- casehub-pages#499 — event-triggered activation (depends on lifecycle state)
- casehub-pages#517 — Serverless Workflow executor (approval workflows deferred here)
