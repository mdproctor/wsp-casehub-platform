---
layout: post
title: "Wiring the Protocol Runtime"
date: 2026-11-22
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [yaml-core, template-extraction, governance, protocol-design, coordination]
series: issue-921-template-variable-extraction
---

# Wiring the Protocol Runtime

The [previous entry](2026-11-20-mdp03-the-template-that-reads-the-room.md) ended with a gap: `TemplateExtractor` and `TemplateRegistry` existed as standalone primitives in yaml-core, but the governance protocol runtime that was supposed to consume them was a hollow skeleton. `PlaybookProtocolEvaluator` had empty method bodies — scaffolded for a future that hadn't arrived yet.

Three changes close that gap.

## Optional Segments

The original template syntax — `"I ${decision} this design because ${rationale}"` — requires every variable to be present. But governance responses often have optional qualifiers. An agent might vote with just `"I approve this design"` or expand with `"I approve this design because the error handling is solid"`.

Bracket syntax handles this: `"I ${decision} this design[ because ${rationale}]"`. The bracketed segment becomes a `(?:...)?` group in the generated regex. When the optional segment matches, the variables inside it appear in the result map as normal. When it doesn't match, those variables are absent — not empty string, absent. The distinction matters downstream: empty string means "the agent said nothing here," absent means "the template didn't ask."

```java
var extractor = TemplateExtractor.compile(
    "I ${decision} this design[ because ${rationale}]");

extractor.extract("I approve this design because the tests are solid");
// {decision: "approve", rationale: "the tests are solid"}

extractor.extract("I approve this design");
// {decision: "approve"}  — no "rationale" key at all
```

Java's named regex groups return `null` for unmatched `(?:...)?` groups, so the implementation is a filter in `extract()` — skip nulls when building the result map.

Escaped brackets (`\[`, `\]`) are treated as literals. Nested brackets are rejected at compile time.

## Dotted Variable Names

`TemplateExtractor` validated variable names against `[a-zA-Z][a-zA-Z0-9]*` — the Java regex named group constraint. This rejected `${context.user}` and `${my-var}`, even though CaseHub's scope model uses dotted paths everywhere and `VariableResolver` already accepts them.

The fix is a name sanitizer between the template's variable names and the internal regex. Dots become `0DOT0` and hyphens become `0HYPHEN0` in the generated group names; the result map restores the originals. The template string and the extraction result both use `context.user` — only the internal regex sees `context0DOT0user`.

The sanitizer delimiter is digit-bounded because Java regex group names only accept `[a-zA-Z][a-zA-Z0-9]*` — no underscores, no hyphens, no dots. I hit this empirically: `_DOT_` looked like the obvious choice and produced `PatternSyntaxException: named capturing group is missing trailing '>'` at every test. Underscores are not valid in Java regex group names. The documentation doesn't emphasize this.

## The Protocol Evaluator

With both features in place, the protocol integration is straightforward. Three types replace the hollow skeleton in `coordination-core/protocol/`:

**`ProtocolDefinition`** — a record holding a protocol name and an ordered map of template name to template pattern. The map preserves insertion order because template matching is first-match-wins, and order is the protocol designer's control surface.

**`ProtocolMatchResult`** — a sealed interface: `Matched(templateName, params)` or `Unmatched(response)`. Callers pattern-match in a switch expression — the compiler enforces exhaustiveness, so adding a third variant later forces all call sites to handle it.

**`ProtocolEvaluator`** — `register()` takes a `ProtocolDefinition`, compiles its templates into a `TemplateRegistry` (fail-fast: invalid templates surface at registration, not at evaluation), and stores it in a `ConcurrentHashMap` keyed by protocol name. `evaluate()` looks up the registry by `ProtocolInstanceKey`, runs first-match, and returns the sealed result.

```java
var protocol = new ProtocolDefinition("design-review", Map.of(
    "approve",  "I ${decision} this design[ because ${rationale}]",
    "escalate", "I escalate to ${target}"
));

evaluator.register(protocol);

var result = evaluator.evaluate(
    new ProtocolInstanceKey("design-review", "review-42"),
    "I approve this design because the error handling is solid"
);

switch (result) {
    case Matched m -> processVote(m.templateName(), m.params());
    case Unmatched u -> askToRephrase(u.response());
}
```

The evaluator is stateless — no `CoordinationStateStore` dependency, no CDI. Advisory generation (`ProtocolAdvisory`, `SuggestedAction`) stays downstream: callers build advisories from match results, the evaluator doesn't opine on what an `Unmatched` response means. That's a policy decision, not a matching decision.

## The Shape That Emerges

The arc from `VariableResolver` (expand templates) through `TemplateExtractor` (extract from templates) to `ProtocolEvaluator` (match agent responses against protocol vocabularies) is now complete. An agent responds in natural prose. The runtime reads it deterministically. No second LLM call to interpret what the first one said.

What's not built yet: YAML protocol definition parsing (templates are still constructed programmatically), and the feedback loop where an `Unmatched` result triggers a rephrase request back to the agent. Those are separate concerns — the matching layer doesn't need to know about them.
