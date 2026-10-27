---
layout: post
title: "Three Documents, Two Merge Strategies"
date: 2026-10-27
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [yaml, parser, playbook, multi-document]
---

# Three Documents, Two Merge Strategies

The playbook YAML format settled on three documents separated by `---`: a front matter header (version and schema), a metadata map (name, description, orchestration config), and a bare action array. Sixty-one playbook files already use this layout. The TS parser handles it fine. The Java `PlaybookParser` didn't — it only read the first two documents and silently dropped the third.

The fix looked straightforward until I looked at the module composition playbooks. Their third document isn't a list at all — it's a map with `name:`, `parameters:`, `imports:`. Two different shapes for the same document position, which means the parser needs two merge strategies:

```java
Object thirdDoc = documents.get(2);
if (thirdDoc instanceof List<?> stepList) {
    metadata.put("steps", stepList);
} else if (thirdDoc instanceof Map<?, ?> mapDoc) {
    metadata.putAll(typedMap);
}
```

When doc 2 is a list, it merges under a `"steps"` key — because that's what `PlaybookCompiler` already expects from `content.get("steps")`. When doc 2 is a map, its entries merge directly into the content. The distinction matters: a bare list of actions is structurally different from a module definition, and wrapping it in a synthetic key preserves that difference for downstream consumers.

The other wrinkle was the playbook name. In the 2-doc format, the name lives in front matter. In 3-doc, front matter is just version and schema — the name moved to doc 1's `playbook:` field. So the parser promotes it: if front matter has no explicit name, the doc 1 value becomes the front matter name, and the key is removed from content to avoid a confusing duplicate where `playbook` means "version" in one place and "name" in another.

The same branch also cleaned up stale type references from earlier rename work — `StepWalker` → `Walker`, `StepResult` → `Result`, `@StepPlugin` → `@Plugin`. The Java renames were already done in prior commits; what remained was a mismatched test filename and a few living documents still using the old names.
