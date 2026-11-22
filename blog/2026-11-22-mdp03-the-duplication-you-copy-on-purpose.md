---
layout: post
title: "The Duplication You Copy on Purpose"
date: 2026-11-22
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [refactoring, playbook-runner, yaml-step-runtime]
---

# The Duplication You Copy on Purpose

When we added the `run(String, PlaybookRunConfig)` overload to `PlaybookRunnerCore` in #931, we copied the step execution loop wholesale from the existing `run(Path, PlaybookRunConfig)` method. That was deliberate — the new overload needed to work immediately, and the two methods differed in enough ways that extracting shared logic mid-feature would have meant designing an API under time pressure.

The result was ~65 lines duplicated between two methods. Same step resolution, same evaluator construction, same trace collection, same capture-to-resolver wiring, same result assembly. The only differences: a source label (`playbookPath.toString()` vs `"<inline>"`) and whether dry-run simulation activates (the Path version supports it; the String version doesn't, because there's no filesystem path to discover a `simulation.yaml` from).

This kind of duplication is a known quantity. You copy it on purpose, ship it, and come back to extract when the shape is settled. The danger is not the duplication itself — it's forgetting to come back.

## The extraction

The shared block became a private `executeSteps()` method taking seven parameters plus a boolean flag:

```java
private PlaybookRunResult executeSteps(
        List<Map<String, Object>> steps,
        String playbookName, String sourceLabel,
        PlaybookRunConfig config, VariableResolver resolver,
        long start, EventCapture eventCapture,
        boolean enableDryRunSimulation)
```

The `enableDryRunSimulation` flag is worth explaining. The Path-based `run()` supports dry-run simulation: it discovers a `simulation.yaml` file from the filesystem, activates it, and wires a simulation checker into the trace collector. The String-based `run()` can't do any of that — there's no filesystem path to walk. Rather than threading the simulation handle through (which would couple `executeSteps` to filesystem concerns it doesn't own), the boolean flag lets the step loop know whether the `config.dryRun()` check should activate the simulation checker. Path passes `true`; String passes `false`. The simulation *activation* stays in each `run()` overload where it belongs.

The extraction also surfaced a dead variable — `stepLookup` was assigned from `stepIndex::get` in both methods but never read. It had been there since the original implementation, quietly copied into the second overload, and now quietly copied into `executeSteps()`. We removed it.

Net result: 75 lines added, 129 removed. Each `run()` overload now handles its specific concerns (parsing, import expansion, simulation activation, error wrapping) and delegates the shared step execution to one place. Any future change to step evaluation — a new decorator, a lifecycle hook, a different capture strategy — happens once.

The kind of refactoring that takes twenty minutes and prevents twenty bugs.
