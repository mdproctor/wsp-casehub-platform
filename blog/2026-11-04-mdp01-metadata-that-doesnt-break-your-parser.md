---
layout: post
title: "Metadata That Doesn't Break Your Parser"
date: 2026-11-04
entry_type: article
subtype: diary
projects: [casehubio/platform]
tags: [yaml-core, playbooks, annotations, design, pre-parser]
---

# Metadata That Doesn't Break Your Parser

YAML has no annotation syntax. Every tool that needs metadata for YAML documents — governance tags, deployment hints, dependency injection markers — has to invent one. The obvious choice is `@timeout(5s)` on a bare line before a step. Clean, readable, instantly familiar to anyone who's used Java or Python annotations.

It also breaks every YAML parser on earth.

The bare `@` is not a valid YAML construct. A pre-parser has to rewrite the text before handing it to SnakeYAML — stripping annotations and reconstructing valid YAML on the fly. That means line numbers shift, error messages point to the wrong place, and any tool that reads the raw YAML (linters, IDE plugins, schema validators) sees something different from what the pre-parser produces.

I chose `#@` instead. A YAML comment that starts with `#@` is a perfectly valid comment — every parser ignores it, every tool passes it through unchanged. The annotation pre-parser reads what the YAML parser skips. Two independent views of the same document, zero transformation, zero line-number drift.

The tradeoff: authors see `#@timeout(5s)` where they'd rather see `@timeout(5s)`. The `#` prefix is visual noise. But the parser correctness is worth it — and the bare `@` rendering can happen in the UI layer, where the source text has already been parsed and the comment is just a display concern.

```yaml
#@description("Customer onboarding")
#@requires(agent, rest-client)
name: Customer onboarding
steps:
  #@timeout(5s)
  - rest-request:
      url: /api/customers
  #@retry(3)
  - agent-invoke:
      prompt: validate response
```

The pre-parser architecture has three pieces. `AnnotationParser` handles the argument grammar — positional args, named args, nested values. `AnnotationExtractor` walks the raw text, identifies `#@` lines, and associates them with either the document or a specific step. `AnnotationMap` holds the result: a list of document-level annotations and a map from step keys to step-level annotations.

Step association is where things get interesting. Top-level steps are easy — count `- ` items after `steps:` and you're done. But playbooks have structural blocks: `block:`, `try:/catch:/finally:`, `if:/then:/else:`, `parallel:`. Annotations inside those blocks need to reach the right nested step.

The extractor uses a `TreeMap<Integer, Integer>` keyed by indent level. Each entry maps an indent depth to the current step counter at that depth. When the extractor encounters a `- ` item, it:

1. Captures the counter at the current indent level (if one exists)
2. Clears all entries at this indent or deeper — leaving a clean parent chain
3. Sets the counter to previous + 1, or 0 for a new level
4. Builds the step key by joining all counters with dots

The dotted key `"0.1"` means "second child of the first step." `"1.0.0"` means "first grandchild of the first child of the second step." The same key format works at any depth — and the `TreeMap` ordering guarantees the parent chain is always read in the right order.

The companion lines (`catch:`, `else:`, `finally:`) are invisible to this algorithm — they're not `- ` items, so the extractor ignores them. Children under `catch:` continue the counter from where `try:`'s children left off. This sequential counting across companion sub-lists matches how the Walker threads annotations through its recursive calls, with offset tracking to keep the numbering aligned.

The decorator migration was the other design decision worth noting. Twelve step decorators — `timeout`, `retry`, `delay`, `priority`, `resource`, `background`, `on-error`, `trigger`, `semaphore`, `at`, `cancel`, `mutex` — can now be expressed as `#@` annotations instead of YAML keys. Both forms work: annotations take precedence, and the old key form emits a deprecation warning. This dual-path lets existing playbooks keep working while new ones adopt the cleaner syntax.

Structural-scoping decorators like `retry condition: [steps]` stay as keys permanently — they wrap child step lists and need YAML structure, not comment-based metadata. That's a distinction worth encoding explicitly rather than discovering later when someone tries to annotate a `retry` that has a condition block and gets confused.

The `@Inject` annotation bridges the gap between YAML declarations and CDI — a playbook can declare `#@Inject(AgentProvider, qualifier: "claude")` and the step evaluator resolves it before execution begins. That wiring opens up scenarios where a playbook's runtime dependencies are visible to tooling before the first step runs — validation, dry-run, capability checking. None of that was possible when services appeared by magic inside step handlers.
