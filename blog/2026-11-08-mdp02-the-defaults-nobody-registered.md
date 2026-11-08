---
layout: post
title: "The Defaults Nobody Registered"
date: 2026-11-08
entry_type: article
subtype: diary
projects: [casehubio/platform]
tags: [expression-engine, platform-defaults, silent-degradation, registry-pattern, CDI, fail-fast]
---

# The Defaults Nobody Registered

CaseHub's expression module has an `ExpressionEngineRegistry` — a pluggable dispatch layer that maps type keys like `"mvel"` or `"jq"` to compiled expression engines. Three engines register themselves at startup. The registry works. You can call `compile("mvel", expression, ...)` and get a compiled expression back.

The registry also has a second API surface: context-aware defaults. Instead of hard-coding which engine evaluates a condition filter, callers ask the registry what the platform default is for a given `ExpressionContext` — CONDITION, TRANSFORM, FILTER, or PARAMETER. The design spec defined the mappings: CONDITION and PARAMETER go to MVEL, TRANSFORM and FILTER go to JQ.

The engines were registered. The defaults were not.

## The Shape of the Bug

`resolveDefault(ExpressionContext.CONDITION)` returns null in production. Not an exception — null. The `EnumMap` that backs the defaults is empty because nobody calls `registerDefault()` during bootstrap. The `ExpressionBeans` producer creates the registry, populates it with engine instances via CDI discovery, and returns it. Three `@Produces` methods for the engines, one for the registry. All clean. All tested. All missing the lines that wire context to engine.

This is an easy class of bug to write. The engine registration is discovery-based — CDI finds the beans, the constructor loops through them, the map populates itself. The default registration is imperative — someone has to call `registerDefault()` explicitly. The mechanism exists. The call site doesn't.

What makes it interesting is how it fails. The `CorpusSelectionEventObserver` — the component that evaluates trigger conditions on CloudEvents — asks the registry for the default CONDITION engine. It gets null. Instead of throwing, it logs a warning and falls back to type-match-only evaluation. The trigger fires on every matching event type regardless of the condition expression. Filters stop filtering.

```java
String engineType = registry.resolveDefault(ExpressionContext.CONDITION);
if (engineType == null) {
    LOG.warning("Trigger '" + triggerName + "' has a condition but no default CONDITION"
            + " engine is registered — trigger will fire on event type match only");
}
```

The warning is correct and helpful — in a log. In production, with dozens of event types flowing through, a warning per trigger per startup gets buried. The system appears to work. Events arrive. Triggers fire. Subscriptions match. The only visible symptom is that conditions are being ignored, and that's only visible if you're specifically checking whether a filter narrowed the result set.

## Why Silent Degradation Is Worse Than a Crash

A `NullPointerException` at startup would have surfaced this immediately. The defensive fallback — designed to be resilient — instead masked the configuration gap. The registry has been deployed since the expression module was built. The default mechanism was added later as part of the subscription engine design. The `registerDefault()` calls that should have accompanied it were never written.

This is a pattern worth watching for in any registry that has both discovery-based and imperative registration paths. CDI, Spring auto-configuration, and service loader all handle the discovery side automatically. The imperative side — the configuration that says "for this context, use that implementation" — depends on someone writing the glue code. It's the kind of code that doesn't have a natural home. It's not the engine's responsibility. It's not the registry's. It falls to the wiring layer, and wiring layers are exactly where gaps hide.

![Expression engine default resolution — before and after](images/expression-default-resolution.svg)

## The Fourth Default

Fixing the three obvious defaults revealed a fourth. `ExpressionContext` has four values, not three. PARAMETER is used by `TypeAwareParamResolver` in the YAML step runtime — it evaluates inline expressions in playbook step parameters. The resolver already had a fail-fast for the missing default:

```java
String engineType = engines.resolveDefault(ExpressionContext.PARAMETER);
if (engineType == null) {
    throw new IllegalStateException(
        "No default expression engine registered for ExpressionContext.PARAMETER");
}
```

This one threw rather than degrading — better behaviour, but it would still have hit production as a runtime exception the first time a playbook used an expression parameter. PARAMETER maps to MVEL for the same reason CONDITION does: both evaluate inline expressions against a context map.

The gap was invisible because nothing in the existing test suite exercised a playbook with PARAMETER-typed inputs through a path that also required registry defaults. The test that would have caught it doesn't exist yet — the type was added recently and the wiring hadn't caught up.

## Making the Fix Stick

Registering the defaults fixed the immediate problem. But nothing prevented the same gap from reopening — remove a `registerDefault()` call during a refactor, and the system silently degrades again.

The fix: a validation loop in the `@Produces` method that creates the registry, right after the defaults are set.

```java
registry.registerDefault(ExpressionContext.CONDITION, "mvel");
registry.registerDefault(ExpressionContext.TRANSFORM, "jq");
registry.registerDefault(ExpressionContext.FILTER, "jq");
registry.registerDefault(ExpressionContext.PARAMETER, "mvel");
for (ExpressionContext ctx : ExpressionContext.values()) {
    if (registry.resolveDefault(ctx) == null) {
        throw new IllegalStateException(
                "No default expression engine registered for " + ctx);
    }
}
```

If someone adds a fifth `ExpressionContext` value without a corresponding `registerDefault()`, the application won't start. The loop iterates the enum values — it doesn't hard-code which contexts to check. Adding a new context automatically makes it a required default.

The `CorpusSelectionEventObserver` also changed. The original warn-and-degrade fallback is now a fail-fast. With defaults guaranteed by the platform, a null from `resolveDefault()` means something is genuinely broken — logging a warning and ignoring the condition was the worst possible response.

## Two Paths Through a Registry

Expression evaluation runs through two distinct paths in CaseHub. The subscription engine takes the explicit path — each subscription carries its own `ExpressionEvaluator` with the engine type baked in, so it calls `compile("mvel", ...)` directly. No default lookup, no gap.

The event-driven path — `CorpusSelectionEventObserver`, `TypeAwareParamResolver`, and anything else that evaluates expressions declared in YAML configuration — takes the implicit path. Configuration says "evaluate this condition" without specifying which engine. The caller asks the registry what the platform default is.

Both paths are valid. The explicit path is self-contained — the engine type travels with the expression. The implicit path is more convenient for configuration-driven systems where specifying `engine: mvel` on every condition is noise. But the implicit path depends on a guarantee the platform must uphold: that every context has a default.

The broader principle: if a registry offers context-aware defaults, the default population must be mandatory and validated at startup. Discovery-based registration handles itself. Imperative registration needs a safety net — because the code that should call it has no natural home, and wiring layers are where gaps hide.
