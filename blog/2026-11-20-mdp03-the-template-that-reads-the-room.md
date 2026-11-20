---
layout: post
title: "The Template That Reads the Room"
date: 2026-11-20
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [yaml-core, template-extraction, governance, regex, protocol-design]
---

# The Template That Reads the Room

Governance protocols need agents to respond in constrained prose — human-readable but structurally predictable. The question is how to extract structured data from those responses without reaching for an LLM classifier.

The answer turns out to be the inverse of something we already have. `VariableResolver` in yaml-core takes a template like `"I ${decision} this design because ${rationale}"` and expands variables into it. `TemplateExtractor` does the reverse: given the same template and an input string, it extracts the variable values back out as a map.

## Why Not Just Use JSON?

The governance use case is a conversation between agents and humans on a shared channel. JSON is structurally unambiguous, but it's hostile to anyone reading the thread. A vote that says `{"decision": "approve", "rationale": "the error handling is solid"}` is machine-perfect and human-unpleasant.

Templates define the protocol's vocabulary in natural language. `"I ${decision} this design because ${rationale}"` says what actions exist and what parameters they carry. The agent responds with `"I approve this design because the error handling is solid"` — readable by everyone on the channel, and the runtime extracts `{decision: "approve", rationale: "the error handling is solid"}` deterministically via regex. No classification ambiguity. No LLM in the extraction loop.

## The Matching Rules

The compile step converts each `${variable}` into a named regex group. The interesting constraint is quantifier selection: variables between literal anchors use lazy matching (`.+?`), and the last variable in the template uses greedy matching (`.+`). This means intermediate variables capture the shortest possible match — anchored by the literals around them — while the final variable captures everything remaining.

```java
var extractor = TemplateExtractor.compile(
    "${first} and ${second} and ${third}");

var result = extractor.extract("a and b and c and d");
// first  → "a"
// second → "b"
// third  → "c and d"
```

Literal segments between variables are `Pattern.quote()`'d, so regex metacharacters in the template text (`$`, `(`, `)`) are treated as literal anchors, not pattern syntax.

Variable names are validated at compile time — they must match `[a-zA-Z][a-zA-Z0-9]*` (the Java regex named group constraint) and duplicates are rejected. Without this, the failure mode is a `PatternSyntaxException` from `Pattern.compile` with no hint about which variable caused it.

## Multi-Template Matching

A single template handles one action. Governance needs several — vote, escalate, abstain, delegate. `TemplateRegistry` takes an ordered set of named templates and returns the first match:

```java
var registry = TemplateRegistry.builder()
    .add("vote",     "I ${decision} this design because ${rationale}")
    .add("escalate", "I escalate to ${target} because ${reason}")
    .build();

var match = registry.match(
    "I escalate to the architecture board because scope changed");
// match.name()   → "escalate"
// match.values() → {target: "the architecture board", reason: "scope changed"}
```

Order matters. More specific templates should come first — a template for `"I approve because ${rationale}"` should precede the general `"I ${decision} because ${rationale}"`, or the general form will match first and the specific one will never fire.

## Where This Leads

The extraction itself is pure — zero dependencies, sits in yaml-core alongside `VariableResolver`. The integration point with governance protocols isn't built yet, but the shape is visible: a protocol definition declares its templates, agents respond in natural prose, and the runtime pattern-matches responses against the protocol vocabulary to extract structured parameters. The LLM produces the prose; the runtime reads it deterministically. No second LLM call to interpret what the first one said.
