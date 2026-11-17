---
title: "Finishing What You Declare"
date: 2026-11-17
entry_type: note
subtype: diary
author: mdp
projects: [casehub-platform]
tags: [playbook, condition-safety, decorators, architecture, yaml]
series: casehub-platform
---

# Finishing What You Declare

A code review turned up something uncomfortable: half the decorator chain in our playbook language was declared but inert. `on-error` caught failures and stuffed marker keys into the result — but never ran the named handler. `transform` compiled, accepted an expression string, and returned the result unchanged. `capture` worked at the top level and silently dropped everything nested inside a block, parallel, or try/catch. The guide documented `invoke:` as a step type; the runtime threw an exception if you tried it.

None of this was broken in the usual sense. Tests passed. Playbooks ran. The features just didn't do what their names implied.

## The Norway problem

The condition evaluator had a subtler issue. Every `when:` guard, `if:` condition, and `loop: until` check followed the same path: substitute variables into the condition text, then evaluate the text. `Truthiness.isTruthy()` handled the boolean conversion, accepting `yes`, `no`, `on`, `off`, `y`, `n`, `1`, `0` alongside `true` and `false`.

The Norway problem: a webhook field containing a country code `NO`, or a configuration value of `0`, evaluates as boolean false. A variable value of `yes` evaluates as true regardless of what the condition was actually checking. The broad truthiness table inherited from YAML's own boolean parsing had leaked into condition evaluation, where it doesn't belong.

Worse: since variables were substituted into the expression text before evaluation, a value containing expression syntax became executable code. If an LLM's output or a webhook payload flowed through a condition, the substituted text would reach the MVEL expression engine — which is a full scripting runtime.

The fix separates the concerns. `Truthiness.isTruthy()` now accepts only literal `true` and `false` — nothing else. A new `isYamlTruthy()` method handles YAML value parsing where the broad table is correct (CSV columns, module parameters, import conditions). The `ConditionEvaluator` gained a three-argument `evaluate(condition, resolver, context)` that checks for literal booleans first, resolves sole variable references to typed values, and delegates to the expression engine with bindings. Variables are resolved before delegation — the expression engine receives concrete values, not template syntax.

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 700 200">
  <defs>
    <marker id="arrowhead" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#555"/>
    </marker>
  </defs>
  <rect x="10" y="30" width="160" height="40" rx="4" fill="#e8f0fe" stroke="#4285f4" stroke-width="1.5"/>
  <text x="90" y="55" text-anchor="middle" font-family="monospace" font-size="12" fill="#333">when: ${var.flag}</text>
  <line x1="170" y1="50" x2="220" y2="50" stroke="#555" stroke-width="1.5" marker-end="url(#arrowhead)"/>
  <rect x="225" y="20" width="140" height="60" rx="4" fill="#fce8e6" stroke="#ea4335" stroke-width="1.5"/>
  <text x="295" y="42" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#c5221f">OLD: substitute</text>
  <text x="295" y="58" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#c5221f">then evaluate text</text>
  <text x="295" y="74" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#888">"no" → false (Norway)</text>
  <rect x="225" y="110" width="140" height="60" rx="4" fill="#e6f4ea" stroke="#34a853" stroke-width="1.5"/>
  <text x="295" y="132" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#137333">NEW: resolve typed</text>
  <text x="295" y="148" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#137333">value, check boolean</text>
  <text x="295" y="164" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#888">Boolean.TRUE → true</text>
  <line x1="365" y1="50" x2="430" y2="50" stroke="#555" stroke-width="1.5" marker-end="url(#arrowhead)"/>
  <line x1="365" y1="140" x2="430" y2="140" stroke="#555" stroke-width="1.5" marker-end="url(#arrowhead)"/>
  <rect x="435" y="30" width="120" height="40" rx="4" fill="#fce8e6" stroke="#ea4335" stroke-width="1.5"/>
  <text x="495" y="55" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#c5221f">MVEL executes</text>
  <rect x="435" y="120" width="120" height="40" rx="4" fill="#e6f4ea" stroke="#34a853" stroke-width="1.5"/>
  <text x="495" y="145" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#137333">safe delegation</text>
  <line x1="555" y1="140" x2="610" y2="140" stroke="#555" stroke-width="1.5" marker-end="url(#arrowhead)"/>
  <rect x="615" y="120" width="70" height="40" rx="4" fill="#e6f4ea" stroke="#34a853" stroke-width="1.5"/>
  <text x="650" y="145" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#137333">boolean</text>
  <text x="90" y="15" font-family="sans-serif" font-size="10" fill="#888">condition input</text>
</svg>

## Finishing the decorators

`on-error` was the most interesting fix. The original implementation caught a failure, turned it into a success, and stashed the handler name in a marker key (`on-error.fallback`). Nothing read that key. The handler never ran.

The real implementation needs three things: a way to find the named step (`StepIndexBuilder` builds a recursive name→step index from the resolved step tree), a way to execute it through the full evaluator (not just the step runner, since a handler can be a block of steps), and correct failure propagation (handler succeeds → error recovered; handler fails → original failure propagates).

This required consolidating DecoratorChain's constructor into a `DecoratorConfig` record — the chain now takes a condition evaluator, speed multiplier, execution scope, step lookup, handler evaluator, handler runner, and transform delegate. That's a lot of wiring, and it's the right amount: each field serves one decorator, and the record makes it extensible for the decorator semantics work coming next.

`transform` was straightforward: apply a `TransformDelegate` (backed by the expression engine) to the step's output map. The key design choice was making it a separate delegate from the condition evaluator — conditions return boolean, transforms return maps, and conflating the two behind a generic interface would force type gymnastics that serve nobody.

## Captures at every depth

Captures inside structural steps — if/then, block, parallel, try/catch — were silently dropped. The fix is a `CaptureCollector`: a thread-safe flat map shared across the evaluator, written from `evaluateInternal` at every nesting depth. The naming model is intentionally simple — flat, globally scoped within the playbook run, last-write-wins on collision. No auto-namespacing by branch path. Playbook authors choose capture names; collisions are their responsibility.

The subtle part: captured values need to be available to downstream steps within the same block. This required threading the updated `StepContext` through `evaluateBlock`'s step loop, so that a step capturing a result makes it visible as `${captureName.field}` in the next step.

## The runner comes home

The runner itself — `PlaybookRunnerCore` — lived in `yaml-test-core`, a test module. The only non-test code that created an evaluator passed no `ExecutionScope` and no expression engine, which meant every coordination primitive (`select`, `cancel`, `background`, `barrier`, `quorum`) returned "requires an ExecutionScope" and any condition beyond a literal boolean threw.

Moving it to `yaml-step-runtime` and wiring the scope was the capstone. The challenge was simulation: `PlaybookRunnerCore.activateSimulation()` imported four simulation modules that would pollute `yaml-step-runtime`'s classpath for every consumer. The solution was a `SimulationActivator` functional interface — the runner accepts it optionally, and the CDI/Spring layers wire the implementation when simulation is on the classpath. `yaml-step-runtime` gains zero new dependencies.

Claude caught the gap I missed: the scope wiring code was written but never called. The runner still used the old 1-arg `StructuralStepEvaluator` constructor that creates everything with null scope. A code review audit after implementation found that none of the new infrastructure — `CaptureCollector`, `StepIndexBuilder`, `DefaultExecutionScope` — was actually instantiated in `PlaybookRunnerCore.run()`. The types were correct; the wiring was absent. Fixed before commit.

## What this enables

WS-1 is the foundation for the playbook language direction. With a canonical runner in main code, wired with scope and expression engine, the downstream work has solid ground: decorator semantics (WS-2) can specify and test contracts knowing the decorators actually execute; the trust model (WS-3) can reason about what's reachable through conditions and expressions; canonical form (WS-4) can reconcile the guide against code that works as documented.

Half-implemented features are worse than missing features. A missing feature is a known gap. A declared-but-inert feature is a false promise — it compiles, it's in the docs, it shows up in the editor schema, and it does nothing when you need it. The hardest part of this work wasn't the implementation. It was finding out how much was declared but never finished.
