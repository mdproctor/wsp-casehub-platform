---
layout: post
title: "Landing the Epic"
date: 2026-10-05
entry_type: note
subtype: diary
projects: [casehubio/platform, casehubio/casehub-pages]
tags: [naming, rebase, multi-doc, yaml, cross-repo]
---

# Landing the Epic

The `epic-502-yaml-parity` branch had been sitting for a while — fifteen commits of playbook infrastructure (error hierarchy, state machine generator, front matter parser, schema registry) that couldn't land because two rename commits conflicted with decisions made on main.

The conflicts were well-documented but needed care. Main had renamed `Scenario*` to `StateMachine*` and `ScenarioScope` to `ExecutionScope`. The epic had renamed the same types to `Playbook*` — a naming direction that was superseded. On top of that, a `StepWalker → Walker` rename needed reverting because `Step*` types are valid internal vocabulary, not something the unification should have touched.

The rebase was fifteen commits onto twenty-seven. Most applied cleanly. The interesting ones: a `parseYaml` method that both branches had added to `ScenarioParser` (now `StateMachineParser`), each with a different approach. The epic's version delegated to `PlaybookParser` for proper front matter extraction — the better design. The rename commit itself got skipped entirely since main already had the right names. After the rebase, an IntelliJ rename refactoring handled the Walker → StepWalker revert across fifty-seven usages.

With the branch clean, fast-forward merge to main and push. No force-push needed — rebase onto local main, merge, push main to remote. The epic branch got a closure stamp.

Then the pages work that the epic had been gating. The three Java parsers in casehub-pages — `ScenarioEnvelopeParser`, `ScriptDescriptorExtractor`, `ScenarioCompiler` — all used Jackson's `readTree()`, which silently drops the second document in multi-doc YAML. No error, no warning. The front matter just vanishes. I wrote a `YamlMultiDocSplitter` that uses `readValues()` with an explicit parser to iterate all documents, extracting `PlaybookFrontMatter` when the first doc has a `playbook:` key. Three lines changed in each parser — swap `readTree(yaml)` for `split.content()`.

The thirteen backend YAML files got their playbook headers next. Mechanical — three lines prepended to each file. Then a terminology sweep: forty-eight occurrences of "CaseHub YAML" became "CaseHub Playbook YAML" across thirty-two files spanning docs, specs, blog entries, tutorials, and a package.json.

What makes multi-repo slot work satisfying is the absence of context switching. Platform rebase, pages parser update, YAML migration, and terminology sweep — four issues across two repos and a workspace — without leaving the slot or losing the thread of what "playbook" means in each layer.
