---
layout: post
title: "When the World Changes Around Your Test"
date: 2026-11-08
entry_type: article
subtype: diary
projects: [casehubio/platform]
tags: [simulation, corpus-selection, event-driven, testing, profiles, state-machine]
---

# When the World Changes Around Your Test

Yesterday's entry covered test doubles that change their mind — a `PhasedCorpus` that switches response data based on which state a selector is in. Step names drive the transitions: when `process-payment` completes, the state machine advances, and the next lookup returns different data. Pure YAML, no Java.

That design has a blind spot. Step completion is one trigger source, but it's not the only reason the world changes around a running workflow. A capacity pressure event fires. A health check fails. An upstream service reports degradation. These aren't step completions — they're environmental signals arriving as CDI events. The state machine can express the transitions, but nothing was wired to fire them.

The second gap is scope. A per-method selector is fine when one API changes behaviour. But an outage scenario hits multiple endpoints simultaneously — the charge API and the refund API both start returning 503s at the same instant. Two independent selectors with identical transition maps will drift if anything goes wrong with either. What you want is one selector driving both.

## Triggers as a separate concern

The first instinct was to put trigger bindings inside the method-level `corpus-selection` block. Each method would declare which events drive its transitions:

```yaml
corpus-selection:
  type: state-machine
  transitions:
    normal:
      pressure-high: degraded
  triggers:                    # ← per-method
    pressure-high:
      event-type: "capacity.pressure"
```

This falls apart the moment you think about `advanceStateMachines()`. That method broadcasts to every registered selector. A trigger binding on method A fires for method B too, if B has the same trigger in its transition map. Per-method bindings are cosmetic — the effect is global.

So triggers are top-level. They map a trigger name to a CloudEvent type and an optional condition expression. The state machine's `transitions` map still owns the topology — which states connect to which. The trigger binding owns the automation — which external event maps to which trigger name:

```yaml
triggers:
  pressure-high:
    event-type: "capacity.pressure"
    condition: "pressure > 0.8"
  outage-start:
    event-type: "service.health"
    condition: "status == 'DOWN'"

methods:
  payment.charge:
    corpus-selection:
      type: state-machine
      transitions:
        normal:
          pressure-high: degraded
          outage-start: error
```

The separation matters. `transitions` defines what happens. `triggers` defines when. Manual `advance()` calls — from MCP tools, from step lifecycle, from test code — still work without any trigger config. Triggers are purely additive automation on top of a state machine that already functions.

## The observer

A CDI `@ApplicationScoped` bean in `event-simulation` watches all CloudEvents. At startup it reads the trigger configs, builds an event-type index, and optionally compiles condition expressions via the platform's `ExpressionEngineRegistry`. When a matching event arrives, it evaluates the condition against the event's JSON payload and calls `advanceStateMachines(triggerName)`.

The condition evaluation is optional in both senses: the `condition` field can be omitted (any matching event fires the trigger), and the expression engine itself is optional on the classpath. If no engine is available, triggers with conditions log a warning and fire on type match alone. This keeps the simulation infrastructure decoupled from any specific expression language — MVEL, JQ, or JEXL all work if present.

## Profile-level selection: one selector, many methods

The outage scenario is the motivating case. When the payment gateway goes down, both the charge endpoint and the refund endpoint need to return errors. With per-method selectors, you'd declare identical state machines on each method and hope they stay in sync. With a profile-level selector, one instance drives both:

```yaml
profiles:
  outage-scenario:
    corpus-selection:
      type: state-machine
      initial: normal
      transitions:
        normal:
          outage-starts: degraded
    methods:
      payment.charge:
        strategy: key-lookup
        phases:
          normal:
            - key: charge
              output: { status: "APPROVED" }
          degraded:
            - key: charge
              output: { error: "SERVICE_UNAVAILABLE" }
      payment.refund:
        strategy: key-lookup
        phases:
          normal:
            - key: refund
              output: { status: "REFUNDED" }
          degraded:
            - key: refund
              output: { error: "SERVICE_UNAVAILABLE" }
```

The profile declares the selector topology — type, initial state, transitions. Each method declares its own phases — what to return in each state. At runtime, `SimulationRuntime` creates one `StateMachineSelector` and shares it across both methods' `PhasedCorpus` instances via a `corpusSelectionGroup` key. When `outage-starts` fires, both methods see `degraded` simultaneously because they're reading from the same `AtomicReference<String>`.

![Trigger binding separation — events drive a shared selector across multiple PhasedCorpus instances](images/trigger-binding-separation.svg)

The `corpusSelectionGroup` mechanism is minimal. `SimulationConfig` gains a default method that returns `Optional.empty()`. `SimulationRuntime.createStrategy()` uses the group key instead of the qualified name when calling `buildSelector` — and `computeIfAbsent` handles the sharing. No new abstractions, no selector registry, no coordination protocol. The `AtomicReference` inside `StateMachineSelector` was already thread-safe. Sharing it is a one-line change to the lookup key.

## External files per phase

One more extension: phases can now reference external corpus files instead of inlining everything. This was the smallest change but it rounds out the configuration model. When your phase has 50 response entries, inlining them in the simulation YAML makes the file unreadable. Pointing to a file keeps the simulation config focused on structure while the response data lives where it belongs:

```yaml
phases:
  normal:
    corpus-files:
      - classpath:simulation/normal-responses.yaml
  degraded:
    corpus-files:
      - classpath:simulation/degraded-responses.yaml
```

Both inline `corpus` entries and `corpus-files` can appear in the same phase — they merge. The loading uses the same `CompositeCorpusLoader` that handles top-level `corpus-files`, so YAML, JSON, and CSV formats all work.

## What this adds up to

The simulation infrastructure started as static corpus data — seed responses at startup, same answers every time. Corpus selection added progression: state machines, duration phases, lookup counts, weighted randomness. Now the progression can be driven by real events, coordinated across multiple endpoints, and configured from external files. The entire simulation scenario is still pure YAML. No Java code to write, no event listeners to register, no coupling between the playbook and the simulation config beyond shared names.

The pattern I keep finding in this work: the right abstraction is the one that's invisible to everything above it. `PhasedCorpus` is invisible to strategies. Triggers are invisible to selectors. Profile grouping is invisible to `PhasedCorpus`. Each layer adds capability without touching the layer above. That's not accidental — it's what makes the YAML-only promise hold as the feature set grows.
