---
layout: post
title: "Wiring the Coordination Layer"
date: 2026-09-28
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [yaml-runtime, orchestration, barrier, quorum, coordination, deadline, deadline-propagation]
series: issue-469-barrier-quorum-sugar
---

# Wiring the Coordination Layer

The step runtime could already run things in sequence, parallel, with conditionals, error handling, and CSP channel selection. What it couldn't do was let steps talk to each other. Every step was fire-and-forget — its output vanished the moment it returned. And there was no way to say "wait here until those three evaluations finish."

The primitives were already sitting in yaml-core. `OrcLatch` wraps a countdown. `StepResultStore` records outcomes keyed by name. `ObjectVariableSource` resolves typed values through `VariableResolver`. All tested, all idle. The gap was the wiring — connecting these primitives to the step evaluator so YAML authors could actually use them.

The design had two parts worth writing about: the variable resolution architecture, and the race condition that the design review caught before any code was written.

## The Composite Map

The spec called for `${result.risk-eval.score}` to resolve a named step's output field, and `${result.risk-eval.error.message}` to drill into a failure's error details. The first attempt had the `ObjectVariableSource` doing its own dot-splitting to detect `error` access patterns. A design reviewer — reading the actual `VariableResolver` source, not the spec — pointed out that this conflicts with how the resolver works internally: typed resolution calls the source with just the root name (`risk-eval`), then `FieldDriller` handles everything after the first dot. The source's dot-splitting would never fire in typed mode.

The fix was a composite Map. Successful steps return their output Map directly — `FieldDriller` navigates `.score`, `.grade`, whatever the action produced. Failed steps return a Map with a single `error` key whose value is the error detail Map. `${result.risk-eval.error.message}` just drills through two levels of Map. No special-casing in the source. The resolver's existing field navigation does all the work.

## Eager Latch Registration

Barrier and quorum both wrap `OrcLatch` — barrier counts down on any step completion (success or failure), quorum counts down only on success. The natural place to create the latch is when the barrier step evaluates. But barrier steps run inside parallel blocks alongside the steps they're waiting for:

```yaml
- parallel:
    - step: momentum-eval
      action: evaluate-momentum
    - step: risk-eval
      action: evaluate-risk
    - step: await-all
      barrier:
        await: [momentum-eval, risk-eval]
```

All three launch on virtual threads. If `momentum-eval` finishes before `await-all` starts executing, the countdown fires with no latch registered. Lost countdown. Barrier hangs forever.

The parent spec (issue-386 §2.2) already had the answer — "created eagerly at scenario load time" — but the implementation spec had drifted from it, wiring registration inside the evaluator. The fix: `preRegisterLatches()` walks the resolved step tree before any evaluation begins, creating all latches and binding step names to them upfront. By the time the parallel executor launches its threads, every countdown target already exists.

Quorum adds one more piece: an `AtomicBoolean` unreachability flag. When enough steps fail that the required threshold can never be met, the tracker drains the latch and sets the flag. The quorum evaluator checks it after `await()` returns — distinguishing "quorum met" from "quorum drained because it was hopeless."

## Making It Production-Safe: Deadline Propagation

Coordination primitives without deadlines are a liability. A barrier waiting on a step that never completes blocks forever. A semaphore acquire inside a timeout block doesn't know the timeout exists — it blocks indefinitely until `Future.cancel(true)` interrupts it, producing an opaque "interrupted" error instead of "deadline exceeded."

The core problem is architectural: the decorator chain's `wrapTimeout` enforces deadlines via `Future.get(timeout)`, but inner decorators — `wrapWait`, `wrapSemaphore` — have no way to query remaining time. The scope hierarchy doesn't help because `wrapTimeout` creates a deadline on a child scope while the evaluator and other decorators reference the parent scope.

I considered three propagation mechanisms. `InheritableThreadLocal` would require zero interface changes — virtual threads inherit thread-locals naturally, and the deadline would flow through parallel execution automatically. But implicit state means a developer adding a new decorator has no signal in the method signature that deadline info exists. They have to know to check `DeadlineContext.current()`. The compiler can't enforce it. A missing check means a hung step inside a timeout block.

The explicit alternative: a `StepContext` carrying `VariableResolver` plus a `DeadlineContext` through the execution chain. `DecoratedExecution.execute(StepContext)` replaces the bare resolver parameter. Every decorator sees `ctx.deadline().remainingTime()` in its signature. `DeadlineContext` is an immutable value type — `withTimeout(Duration)` composes via `Math.min(existing, new)`, so nested timeouts naturally produce the tighter deadline without any special nesting logic.

The refactoring touched every decorator lambda in DecoratorChain and every dispatch method in StructuralStepEvaluator — roughly 25 method signatures across two files. Mechanical, but the result is that `wrapWait` and `wrapSemaphore` now check `ctx.deadline().remainingTime()` and use timed variants (`signal.await(remaining, MILLISECONDS)`, `semaphore.tryAcquire(remaining, MILLISECONDS)`) when a deadline exists. The error messages say "exceeded deadline" — the developer debugging a hung scenario sees exactly what happened, not a generic interruption.

## What This Opens Up

The coordination layer is now complete enough to support the target pattern: fork evaluation across parallel strategies, synchronise at a barrier, consume results via `${result.<step>}`, and know that the whole thing has a time budget. A `timeout: 30s` on a parallel block propagates to every signal wait and semaphore acquire inside it — if step A takes 25 seconds, step B's semaphore acquire gets 5 seconds, not infinity.

The deadline mechanism is deliberately lightweight. `DeadlineContext` tracks an absolute nanos timestamp — no scope hierarchy, no watcher threads, no cleanup cascades. The `ScenarioScope.withDeadline()` API exists for cases that need scope-level enforcement with primitive release on expiry. The two mechanisms are complementary: scope deadlines for infrastructure cleanup, `DeadlineContext` for cooperative awareness.
