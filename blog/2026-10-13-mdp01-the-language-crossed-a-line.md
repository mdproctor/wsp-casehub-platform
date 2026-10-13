---
layout: post
title: "The Language Crossed a Line"
date: 2026-10-13
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [yaml-language, orchestration, decorators, stream-processing, playbook, concurrency]
---

# The Language Crossed a Line

Two weeks ago the playbook language could run steps in sequence, parallel, with retry and timeout. Useful, but limited — a step runner with guardrails. Today it can express concurrent pipelines with backpressure, resource contention with priority, cancellation propagated through scope trees, and stream fan-in/fan-out — all without a stream DSL, without new step types, without any framework dependency beyond `java.util.concurrent`.

The change wasn't one feature. It was twelve, and each one felt small when it landed.

## What Actually Changed

The decorator chain — the thing that wraps every step invocation with retry, timeout, loop, error handling — grew six new positions. Each decorator is independent. Each composes with the others. The interesting part isn't any single decorator; it's what happens when you combine them.

`at:` is a threshold gate. It blocks until a counter, accumulator, or gauge crosses a value. Put it on a step inside a `loop: continuous` and you have a reactive trigger that fires every time pressure exceeds a threshold — not a polling loop, a blocking wait on a concurrent primitive.

`resource:` binds a step to a named contended resource — a priority-aware semaphore. `priority: background` means this step yields to higher-priority work competing for the same resource. The runtime doesn't schedule — the decorator acquires a semaphore with priority ordering, and virtual threads handle the rest.

`cancel:` is the dual of `timeout:` — same interrupt mechanism, but triggered by a signal instead of a clock. A step decorated with `cancel: abort-signal` will be interrupted when any other step fires that signal. Combined with `background:`, which spawns a step via `scope.spawn()` and returns immediately, you get long-running background work that can be cleanly terminated from elsewhere in the playbook.

And then `from:`, the one that turned the step runner into a stream processor.

## Streams Without a Stream DSL

`from:` reads one item from an `OrcChannel` per step invocation. That's it — one decorator, one blocking call. But inside `loop: continuous` with `background: true`, it becomes a continuously running pipeline stage:

```yaml
- action: enrich-reading
  from: { channel: raw-readings, as: reading }
  retry: { max: 3, on: TRANSIENT }
  loop: continuous
  background: true
  publish: { channel: enriched }
```

This step runs forever in the background. Each iteration reads one item from `raw-readings`, retries up to three times on transient failure, and publishes the result to `enriched`. Backpressure comes from the channel's bounded capacity — when `enriched` is full, `publish:` blocks until a downstream consumer drains it. No special backpressure API. No reactive streams library. The JDK's `SubmissionPublisher` semantics, but expressed as YAML decorators.

Fan-in is `from: { channels: [fire-alerts, flood-alerts], as: alert }` — read from whichever channel has data first. Fan-out is `publish:` in list form with per-channel conditions:

```yaml
publish:
  - { channel: normal, if: "${result.class} == NORMAL" }
  - { channel: anomaly, if: "${result.class} == ANOMALY" }
```

Three independently running stages, each with its own error handling and retry policy, connected by bounded channels. That's a pipeline. It emerged from composing five existing decorators — `loop`, `background`, `from`, `retry`, `publish` — none of which was designed for stream processing.

## The Naming That Wasn't Just Naming

In the middle of all this, the language got renamed. Scenario became Playbook. `.scenario.yaml` became `.playbook.yaml`. The `ScenarioParser` became `StateMachineParser`. Seven repos, hundreds of files, every reference updated.

It sounds cosmetic. It wasn't. The old name carried baggage — "scenario" implied a test fixture, something you run once to verify behaviour. The playbook language had outgrown that. It orchestrates production workloads, manages concurrent state, coordinates agent execution. Calling it a scenario was actively misleading new users about what it could do.

The rename also forced a cleanup. Stale types surfaced — parsers that hadn't been used since the hierarchical format replaced the flat one, dead code paths that the naming search revealed. We deleted more lines than we renamed.

## What It Means

The playbook language is now a coordination language. A YAML author can express:

- **Pipeline:** source → filter → enrich → sink, each stage independently retried and resource-bounded
- **Fan-in:** merge alerts from multiple channels into a single handler
- **Fan-out:** route results to different channels based on content
- **Resource contention:** multiple steps competing for a shared resource with priority ordering
- **Cancellation:** signal-driven interruption of background work
- **Threshold triggers:** steps that fire when counters cross boundaries

None of this required a new runtime. The step evaluator still calls `DecoratorChain.apply()`, which wraps the step in a stack of lambdas. The chain grew from eight positions to fourteen. Each position is a pure function: `DecoratedExecution → DecoratedExecution`. The complexity lives in composition, not in any single piece.

The thing that makes me most confident about the design: windowed aggregation isn't in the language. It's a plugin concern — a step action that happens to buffer items and emit averages. The language orchestrates it with `from:` and `publish:`. If windowing needed a language primitive, the abstraction would be wrong.
