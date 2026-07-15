---
layout: post
title: "Killing the Constraint Model"
date: 2026-07-15
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [subscriptions, expressions, mvel3, alpha-network]
---

The subscription system had a `Constraint(field, op, value)` model — structured triples that got AND'd together and compiled to MVEL. It worked for simple cases: `status == active`, `priority IN HIGH,CRITICAL`. The issue was what came next.

OR logic? Extend `ConstraintOp` with compound types. Nesting? Add a recursive group model. Cross-field comparisons like `deadline < createdAt + 7d`? Now you're rebuilding an expression language, badly, inside a data model that was never designed for it.

The expression SPI we'd just landed (#141) already had MVEL and JQ engines with lazy compilation, parameterized variable binding, and a concurrent cache. Every capability `Constraint` would need to grow into already existed one layer down. The structured model was just a translation step that deferred the inevitable.

So we removed it. `Subscription` now carries `List<ExpressionEvaluator>` — each entry is a typed expression (MVEL or JQ) that the `SubscriptionEngine` compiles directly via `ExpressionEngineRegistry`. The `ConstraintCompiler` that sat between the two is gone. `Constraint` and `ConstraintOp` are deleted from platform-api entirely.

The interesting part was what didn't change. The alpha network — `TypeNode`, `FilterNode`, `FilterExpression` with collapsed sharing — doesn't know or care what produced the `FilterExpression`. Two subscriptions with identical MVEL expressions in the same tenant still share a `FilterNode` and evaluate the predicate once. The sharing identity is the expression string, not the input model. Swapping `Constraint` triples for raw expressions didn't touch a single line in `datasource-alpha`.

Tenant isolation moved from a hidden concern inside `ConstraintCompiler` to an explicit wrapping predicate in `SubscriptionEngine`. The `$me` owner placeholder became a bound MVEL variable instead of a string substitution — cleaner, and it works natively with MVEL's compilation model.

One gotcha surfaced during testing: MVEL3 doesn't support single-quoted string literals. `status == 'completed'` throws an `UnsolvedSymbolException` because the transpiler tries to resolve `mpleted` as a Java identifier. The old compiler never hit this because it used parameterised variables (`$p0`) instead of string literals. Double quotes work: `status == "completed"`. Non-obvious if you're coming from MVEL2, which treated both quote styles identically.

The net result is 36 fewer lines of code and one fewer abstraction layer. More importantly, the subscription filter model is now the expression SPI — it doesn't need to grow its own feature set to handle complex predicates.
