---
layout: post
title: "The Toolbox That Isn't a Framework"
date: 2026-08-29
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [yaml, design, j2cl, adapter-pattern, extraction]
series: issue-247-shared-yaml-core
---

# The Toolbox That Isn't a Framework

Two CaseHub repos — desiredstate and pages — both process YAML declarations.
Both resolve `${prefix.name}` variables. Both expand `forEach` templates into
stamped copies. Both evaluate `when` conditions as boolean strings. The
implementations diverged years ago, and now they disagree on edge cases.

The obvious fix is extraction: pull the shared primitives into a platform
module. The less obvious question is what shape that module takes.

## The framework trap

The tempting design is a `YamlDialect` — a configuration object that declares
which primitives are active, validates input against that declaration, and
orchestrates a compilation pipeline. Plug in your dialect, hand it a YAML
document, get back structured output. Clean, discoverable, type-safe.

It's also wrong for this problem. The two consuming domains don't share a
compilation pipeline. Desiredstate runs a three-pass expansion (classify
nodes → stamp copies → wire dependencies). Pages runs a single-pass
linear walk. A shared pipeline would either be too rigid for desiredstate
or too loose for pages. The dialect layer adds validation that duplicates
what each domain already does differently, and it couples primitives that
don't need to know about each other.

## Toolbox composability

What we built instead is a toolbox: four independent packages, each a
self-contained utility. A domain that only needs variable resolution imports
only the `resolver/` classes. A domain that wants `forEach` expansion pulls
in `foreach/` — which depends on `resolver/` and `condition/`, but that
dependency is internal, not something the consumer configures.

The key design is the `ForEachAdapter<E>`. The original desiredstate
`ForEachExpander` is tightly coupled to `YamlNode`, `DesiredNode`,
`NodeSpecRegistry`, and Jackson's `ObjectMapper`. It stamps copies by
resolving specs through the registry, converting via Jackson, and
constructing domain-specific `DesiredNode` instances. All of that is
domain logic wearing infrastructure clothes.

The shared version strips the expander to its algorithmic core — iterate,
stamp, evaluate conditions, track exclusions — and pushes everything
domain-specific into a four-method adapter:

```java
public interface ForEachAdapter<E> {
    E stamp(E template, String stampedId, VariableResolver scopedResolver);
    Object getForEach(E element);
    String getId(E element);
    String getWhen(E element);
}
```

The expander handles the iteration mechanics. The adapter handles what "stamp
a copy" means in your domain. Desiredstate's adapter will do spec resolution,
type conversion, and hook resolution. Pages' adapter will do something simpler.
Neither needs to know about the other.

## Deferred prefixes replace dual APIs

The existing `VariableResolver` had two parallel APIs: `resolveString()` which
throws on unresolved variables, and `resolveTemplateString()` which passes
through variables with unknown prefixes. Desiredstate used the first for node
specs (where `match.*` and `fault.*` must fail) and the second for rule specs
(where `match.*` and `fault.*` should survive until runtime).

We collapsed this to a single API with a `deferredPrefixes` set. A resolver
created with `Set.of("match", "fault")` passes those prefixes through silently.
A resolver created with `Set.of()` throws on everything unknown. Same
behaviour, one code path, and the configuration makes the intent explicit at
construction time rather than hiding it in which method you call.

## J2CL as a design discipline

The module is constrained to be J2CL-transpilable — no reflection, no
`ConcurrentHashMap`, no CDI, no Jackson. These constraints aren't enforced by
a build tool; they're a coding discipline documented in the spec and verified
by code review.

This shaped several decisions. The `CsvParser` can't use a CSV library (most
use reflection for bean mapping). The `ForEachExpander` can't parse JSON arrays
from variable-resolved iteration values (that needs Jackson). So JSON parsing
stays in the domain — the shared expander resolves variables in `in` values
and returns strings; the domain decides whether those strings need further
parsing.

The constraint also ruled out `ConcurrentHashMap` in `VariableResolver`, which
forced the immutable-child pattern: `withEachContext()` and `withScope()` return
new resolver instances rather than mutating shared state. This is arguably a
better design than the thread-safe-mutable alternative, arrived at through
constraint rather than preference.

## The fourth primitive

Three of the four primitives — variable resolution, forEach expansion,
conditional inclusion — are ports of existing production code. The fourth,
typed CSV data sources, is new. Including it in the first cut was a deliberate
choice: the `CsvParser` integrates with `VariableResolver` through
`withEachRowContext()` (drilling into row fields via `${each.env.name}`)
and with `ForEachExpander` through the iteration value mechanism. Deferring it
would have meant a second round of `VariableResolver` API changes when the
row context support inevitably needed adjusting.

The typed column system (`STRING`, `INTEGER`, `BOOLEAN`, `DECIMAL`) validates
at parse time with row-and-column error context. `BOOLEAN` delegates to
`Truthiness` — a minor detail, but it means boolean semantics are consistent
whether a value comes from a `when` condition or a CSV cell.

Each primitive also ships a JSON Schema fragment. Domains compose their full
YAML schema by referencing these via `$ref` — a domain that doesn't support
`forEach` simply omits the forEach fragment, and its schema validation rejects
`forEach:` keys with a clear error. The fragments are pure resource files with
no runtime cost.

The module is twelve types, five schema fragments, and zero dependencies. It
does one thing, and each domain takes exactly the parts it needs.
