---
layout: post
title: "CloudEvent dispatch and the MVEL3 transpiler's blind spots"
date: 2026-07-18
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [cloudevents, cdi, mvel3, expression-engine]
series: issue-176-expression-spi-and-cloudevent
---

Two separate problems landed on the same branch: how to let modules receive specific CloudEvent types without the full DataSource machinery, and how to make MvelExpressionEngine work with POJOs instead of just Maps. They turned out to have nothing in common except timing — and both surfaced things I hadn't expected.

## The qualifier trick

The CloudEvent bus fires `Event<CloudEvent>.fireAsync()` to the CDI bus. DataSourceRouter catches everything and routes to wired DataSources — that's the complex event processing path. But neocortex just wants `io.casehub.cbr.outcome` events. Wiring up a DataSource, ObjectType, alpha network subscription, and marshaller for "give me events of this type" is heavyweight for what amounts to a CDI observer.

The fix is a `@CloudEventType` CDI qualifier. A `CloudEventTypeDispatcher` observes unqualified CloudEvents and re-fires with `cloudEventBus.select(new CloudEventTypeLiteral(type)).fireAsync(event)`. Consumers declare what they want: `@ObservesAsync @CloudEventType("io.casehub.cbr.outcome") CloudEvent event`.

The part I hadn't appreciated: CDI's `Event.select()` removes `@Default` when user qualifiers are added. DataSourceRouter has implicit `@Default` on its observer — so it doesn't receive the re-fired qualified event. No double processing, no infinite loop, no guards needed. The CDI spec handles it automatically. Every existing `@ObservesAsync CloudEvent` observer is protected — DataSourceRouter, RasEngine, anything added in the future.

## MVEL3's transpiler doesn't do what you'd expect

MvelExpressionEngine compiled against `Map<String, Object>` only. The engine migration needs POJO context — CaseContext is a POJO, and the engine evaluates expressions against it. `MVEL.pojo(cls).out(resultType).expression("name").compile()` should handle this. It doesn't.

The transpiler has a NameExpr rewriter that converts bare property names (like `name`) to getter calls on the context object. But the rewriter checks `withDeclaration.type().isVoid()` — and when no `.with()` root is set, it skips rewriting entirely. The bare name stays as a standalone variable reference. The generated Java fails javac, and the resulting NPE in `MVELCompiler` points at generated evaluator code, not at the transpiler's rewriting logic.

We worked around it with a JavaBean introspection adapter: `Introspector.getBeanInfo(contextType)` extracts property descriptors, `eval()` converts the POJO to a Map via getter reflection, then delegates to the proven Map compilation path. The compile API is unchanged — `compile("name", Person.class, String.class)` works transparently.

Block expressions hit a similar gap. MVEL2 implicitly returned the last expression's value. MVEL3 transpiles to Java, and `x + threshold;` is not a valid Java statement — javac rejects it with "not a statement." Block expressions need explicit `return`: `var threshold = 10; return x + threshold;`. MVEL3's own `executeExpression()` uses `expr.indexOf(';') > 0` for block detection, so we adopted the same heuristic.

Three MVEL3 gotchas in one session. The `contains` keyword and single-quote issues from last session make five total. The transpiler architecture — MVEL source → JavaParser AST → Java source → javac → bytecode — means every Java constraint applies to the generated output. The error messages point at the generated code, never at the MVEL-specific cause.

The engine migration issues are filed against casehub-engine. Platform's expression SPI is ready — POJO context works, block expressions work, the compile API is unchanged. The engine side is four issues: extend ExpressionEvaluator, wrap ExpressionEngine, replace LambdaExpressionEvaluator, delegate the registry.
