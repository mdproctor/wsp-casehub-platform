---
layout: post
title: "Closing the Protocol Gap"
date: 2026-11-22
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [yaml-core, protocol-design, coordination, playbook-runtime]
series: issue-921-template-variable-extraction
---

# Closing the Protocol Gap

The [previous entry](2026-11-22-mdp37-wiring-the-protocol-runtime.md) ended with a named gap: protocol definitions were constructed programmatically, and playbooks could only be run from files on disk. Both constraints felt like temporary scaffolding that would need to come down before anything useful could grow on top.

## Declarative Protocol Definitions

`ProtocolEvaluator.register()` takes a `ProtocolDefinition` record — a name and an ordered map of templates. The programmatic API works, but governance protocols should be configuration, not compiled code. A domain expert defining a review vocabulary shouldn't need to write Java.

`ProtocolDefinitionParser` closes this. A YAML file with a `templates:` section becomes a `ProtocolDefinition`:

```yaml
templates:
  approve: "I ${decision} this design[ because ${rationale}]"
  escalate: "I escalate to ${target}"
  abstain: "I abstain[ because ${reason}]"
```

```java
ProtocolDefinition def = ProtocolDefinitionParser.parse(
    "design-review", inputStream);
evaluator.register(def);
```

Validation happens at parse time, not at registration. `TemplateExtractor.compile()` runs against every template pattern during parsing — a malformed variable name like `${1invalid}` or an unclosed optional bracket surfaces immediately as an `IllegalArgumentException` naming the offending template. The alternative — storing the raw strings and discovering the problem at the first `evaluate()` call — would push errors to runtime, possibly minutes later and in a completely different call stack.

The parser uses Jackson's `YAMLFactory` with `PARSE_BOOLEAN_LIKE_WORDS_AS_STRINGS` enabled. Without this flag, a template value of `yes` would be parsed as `Boolean.TRUE` and silently converted to the string `"true"` — semantically wrong for a protocol vocabulary where the literal word matters. I caught this during code review; the initial implementation used a bare `YAMLFactory` and would have corrupted any template containing a YAML boolean-like word.

## Playbooks Without the Filesystem

`PlaybookRunnerCore.run()` required a `Path` — it called `Files.readString()` on line one, then threaded the path through import expansion, simulation activation, name extraction, and result reporting. The qhorus playbook protocol bridge stores definitions in a database and dispatches them as strings. Without a string overload, every dispatch evaluation would write YAML to a temp file on a hot path.

The new `run(String yamlContent, PlaybookRunConfig config)` overload handles the differences explicitly rather than trying to unify everything behind a shared private method. Import expansion — which needs a filesystem path for relative module resolution — is rejected with a descriptive error. Simulation activation is skipped (it requires a path for sibling `simulation.yaml` discovery). The source identifier in results becomes `"<inline>"` instead of a file path. The playbook name falls back to `"<inline>"` when neither front matter nor YAML content provides one.

The import restriction is a deliberate scope boundary. Inline playbooks are self-contained execution units — a protocol handler dispatching a stored definition. If that definition needs module imports, it belongs on the filesystem where the module loader can resolve paths. Trying to support both would mean inventing a virtual filesystem abstraction that nothing else in the codebase needs.

## What the Parser Unlocks

The connection between these two changes is the pipeline they enable. A governance protocol's vocabulary lives in a YAML file, versioned and loaded at startup. An agent responds in natural prose. The `ProtocolEvaluator` matches deterministically — no second LLM call to interpret what the first one said. When the matching happens inside a playbook step, that playbook can itself be loaded from a database, dispatched as a string, and executed without touching the filesystem.

Configuration in, prose in, deterministic match out. The declarative layer is now complete from storage to evaluation.
