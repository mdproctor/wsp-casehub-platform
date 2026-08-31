---
layout: post
title: "When the Review Is Right"
date: 2026-08-31
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [yaml, design, module-system, decision-review, api-design]
series: issue-252-yaml-core-modules
---

# When the Review Is Right

I went into the module system design with two convictions that turned out to
be wrong. Not wrong as in "bad ideas" — wrong as in "solving the problem at
the wrong layer."

The first was `withModuleScope()` on `VariableResolver`. Module parameters
need highest priority when resolving `${var.*}` references inside a module's
content. I wanted that priority to be explicit — a named method on the
resolver, not buried in a chain order. The decision review disagreed: module
scope IS a `VariableSource`. `Map<String, String>::get` already satisfies the
`@FunctionalInterface`. Chain order IS the priority mechanism — that's the
defining semantic of `VariableSource.chain()`. Calling it "implicit" was like
calling middleware order implicit. It's the design.

The second was `validate()` that throws. Parameter validation failures are
always fatal — a module can't expand with invalid parameters. So I designed
the API around the throwing case: call `validate()`, get either silence or an
exception full of violations. The review pointed out that the composable
primitive is the return value, not the exception. Testing is cleaner —
asserting on a returned list vs catching an exception to inspect its
violations list. The throwing method is a convenience built on top, not the
foundation.

Both revisions cost nothing to apply. `withModuleScope()` became
`VariableSource.chain(moduleParams::get, existingSource)` — one line, no new
field on the resolver, no split resolution model. `validate()` became a
`List<ParameterViolation>` return with `validateOrThrow()` alongside it for
the common case.

What's interesting isn't that I was wrong — it's that both mistakes came from
the same instinct: making the important thing loud. Explicit method for
priority. Exception for fatality. But "loud" added complexity without adding
information. The chain order already documents priority. The list return
already communicates violations. Both designs were trying to signal something
the existing abstractions already expressed.

The module system itself is a generic extraction from desiredstate's
domain-coupled implementation. `YamlModule` holds opaque `Map<String,
Map<String, Object>>` sections instead of `YamlNode`, `YamlRule`,
`YamlInvariant`. `ModuleExpander` handles alias prefixing, parameter
resolution, and import merging — structural operations on the envelope. The
consumer casts sections to domain types at the boundary, one
`objectMapper.convertValue()` call per section.

`ParameterValidator` collects all violations — not fail-fast. Type-aware
constraints: `minLength` on a LIST counts elements, not characters. Pattern
matching on a LIST applies per element. This is a deliberate JSON Schema
subset — just enough for module parameters, without importing a validation
library into a zero-dep module.

The import structural validation was another review catch — the existing
desiredstate code checks for null aliases, dots in aliases, and duplicate
aliases, but my spec didn't mention any of them. Silent corruption from a
null alias producing `"null.cpu-check"` as a key, or a dotted alias breaking
variable resolution — the kind of bugs that pass all tests and surface three
repos downstream.

Six decisions went in. Two came back revised. Both revisions made the design
simpler. That's the outcome you want from a review — not "you were wrong"
but "here's the same thing with less."
