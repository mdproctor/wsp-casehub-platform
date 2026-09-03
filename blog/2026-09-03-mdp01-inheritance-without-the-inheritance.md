---
title: "Inheritance Without the Inheritance"
date: 2026-09-03
author: mdp
entry_type: note
subtype: diary
projects:
  - casehubio/platform
series: issue-269-module-extension-extends
tags: [yaml-core, modules, extension, inheritance, api-design]
---

# Inheritance Without the Inheritance

yaml-core's module system has supported composition since #252 — a graph imports modules as building blocks, the expander handles alias prefixing and parameter resolution. What it didn't support was extension: a module inheriting another module's content and adding to it.

The design choice that made this interesting was where the `extends` field lives. The YAML is obvious — `extends: monitoring` in the module header. But `extends` has the same lifecycle as `imports`: consumed during resolution, then discarded. The resolved `YamlModule` is self-contained. No ancestry metadata, no parent pointer, nothing downstream needs to know about. This meant `extends` belongs on `YamlModuleHeader` (the file model), not on `YamlModule` (the logical model). `toModule()` discards it, same as it discards the import list.

The resolution itself is a pre-processing step — `ModuleExpander.resolveExtensions()` takes a `List<YamlModuleFile>`, merges parents into children, and returns a `Map<String, YamlModule>` ready for `expand()`. The caller's pipeline gets one new step and the expansion engine doesn't change at all.

Merge semantics are deliberately shallow. Parameters and outputs: child replaces parent's entirely on name match. Sections: merge by section name, child entry replaces parent's entry on key conflict. No deep merge of entry values — yaml-core treats them as opaque `Object` and has no structural knowledge of what's inside. A child overriding a parent's `monitor` node replaces the whole node, not individual fields within it.

This is the right boundary. Consumers who want deep merge — say, overriding a single field in a node spec without redeclaring the whole node — have `ModuleBridge<T>` for that. The bridge has the typed knowledge needed for field-level merging. yaml-core doesn't, and shouldn't.

Single-level only. No A-extends-B-extends-C chains. Same rationale as the D10 nesting cap for composition: deep inheritance in declarative module systems is a debugging problem that gets worse faster than the abstraction helps. If a use case genuinely needs chains, we'll revisit — but not without evidence that single-level isn't enough.
