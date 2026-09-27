---
layout: post
title: "Wiring the Coordination Layer"
date: 2026-09-28
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [yaml-runtime, orchestration, barrier, quorum, coordination]
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

## What This Opens Up

The combination matters more than the individual pieces. `${result.<step>}` alone lets sequential steps consume each other's output. Barrier alone lets parallel work synchronise. Together, they enable the pattern the spec was designed around: fork evaluation across parallel strategies, wait at a barrier for all of them, then use their results to make a decision. Quorum makes the voting variant possible — proceed when two of three strategies agree, without waiting for the slow one.

The next issue on the branch is deadline propagation — parent timeouts creating child `ScenarioScope` deadlines. That's the piece that makes the coordination primitives production-safe: without it, a hung barrier blocks forever. With it, the parent scope's deadline cascades through and interrupts the wait.
