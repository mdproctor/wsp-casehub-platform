---
title: "Type Safety as Documentation"
date: 2026-09-01
author: mdp
entry_type: note
subtype: diary
projects:
  - casehubio/platform
series: issue-261-yaml-core-type-safety
tags: [yaml-core, type-safety, sealed-types, java, api-design]
---

yaml-core has been accumulating `Object` returns and positional parameter lists since it was first written. Everything worked, but the API was lying to the compiler about what it knew. `ParameterType.parse()` returned `Object`. `ForEachAdapter.getForEach()` returned `Object`. `YamlModuleParameter` took ten positional arguments, seven of them usually null. The code compiled, the tests passed, and every caller silently took on the burden of knowing which casts were safe.

We audited the whole module — every source file, every test, every schema fragment, and the primary consumer in yaml-codegen. Claude produced a structured finding list with sixteen items spanning type safety, API design, and YAML authoring experience. The interesting thing was the split: most findings were purely internal Java improvements, but a few directly affected what YAML authors experience when they write case definitions.

The YAML-facing wins are the ones I'm most satisfied with. A module author could declare `type: STRING` with `minimum: 5` and the constraint would silently do nothing — the minimum check only fires for numeric types. Now the builder catches that at definition time: "minimum/maximum constraints are only valid for INTEGER and NUMBER parameters, not STRING. Did you mean minLength/maxLength?" That error message alone would have saved someone a debugging session eventually.

Similarly, `CsvColumnType` had `DECIMAL` where `ParameterType` had `NUMBER` for the same concept. A YAML author writing both CSV data sources and module parameters encounters both names. We aligned them — `DECIMAL` is now `NUMBER` everywhere. Pre-release, so the rename is free.

The `allowedValues` check was string-only by accident. A YAML author writing `type: BOOLEAN` with `allowedValues: ["true"]` couldn't use `yes` or `on` as input — those parse to `true` internally but fail the string comparison against `"true"`. Now the validator compares both the raw string and the canonical parsed form, so truthiness aliases work through `allowedValues`.

On the Java side, the sealed types are the real payoff. `ParsedValue` replaces the `Object` return from `parse()` with five concrete record types — `StringValue`, `IntegerValue`, `NumberValue`, `BooleanValue`, `ListValue`. The validator now pattern-matches on these instead of `instanceof Number` guards. `ForEachDirective` replaces the `String`-or-`Map` duck typing in forEach with `GroupRef` and `InlineIteration` records. The `resolveAs` method went from three instanceof branches and a throw to a two-case exhaustive switch.

The builder for `YamlModuleParameter` was the biggest UX improvement for Java consumers. Constructing a parameter went from `new YamlModuleParameter(ParameterType.STRING, true, null, null, null, null, null, null, List.of(), null)` — count the nulls — to `YamlModuleParameter.builder().type(ParameterType.STRING).required().build()`. The builder also validates constraint/type coherence at build time, which means the error surfaces where the author wrote the code, not where the constraint silently fails to fire at runtime.

What makes the sealed types interesting beyond just "better types" is that they function as documentation. A new contributor reading `ForEachDirective` immediately sees there are exactly two kinds of forEach: group references and inline iterations. They don't need to grep through `ForEachExpander` to discover that `Object` means "String or Map with an 'as' key and an 'in' key." The type hierarchy IS the documentation. Same with `ParsedValue` — the five variants tell you exactly what `parse()` can produce.

The zero-dep constraint held throughout. Everything uses `java.util` only. No reflection, no annotation processing, no framework. The sealed types, records, and pattern matching are all standard Java 21 features that work under J2CL transpilation. That was never in doubt for this change — sealed interfaces are pure language features — but it's worth confirming since yaml-core's dependency-free status is load-bearing for the build order.

All of this landed in four commits with a clean code review — zero CRITICALs, two WARNINGs (a stray brace and a missing null guard on `InlineIteration.as`), two NOTEs (FQN imports that should have been standard imports). The branch audit across all four dimensions came back clean. Twenty-four files changed, mostly in a tight refactoring pattern: change the production type, update the validator/expander, fix the tests. The ratio of new test code to new production code is roughly 1:1, which feels right for a type safety refactoring where the tests themselves become more expressive.

The module schema fragment (`module.schema.json`) rounds it out on the YAML side — parameters, outputs, imports all documented for IDE autocompletion. This was the most structurally complex part of yaml-core and the only part without a JSON Schema. Now YAML authors get completion for the part they most need it.
