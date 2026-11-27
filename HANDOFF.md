# HANDOFF — casehub-platform

**Last worked:** #961 + #972 — consumer migration and version safety (done, landed)
**Branch:** `issue-972-atomic-namespace-version` (stacked on `issue-961-consumer-migration`)
**This session landed:** #961, #972

## This session

Two issues under epic #943 (unified template registry):

**#961 — Consumer migration:** Migrated `PlaybookRunnerCore` from creating per-playbook `TemplateMatchingFilter` instances to registering `TemplateNamespace` with the shared `UnifiedTemplateRegistry`. Removed `NlpProtocolMatcher` dependency. Deleted `ProtocolEvaluator` and 8 ancillary types from coordination-core. Deleted `message-extraction-api` and `message-extraction` modules (~2,500 lines removed).

**#972 — Version safety:** Added monotonic `version` field to `TemplateNamespace` and `TemplateMatch.Matched`. Implemented bounded version history ring in `InMemoryTemplateRegistry` Snapshot (default 3 previous versions). Added `match(namespace, input, version)` overload for dispatch-time version pinning. Created `NamespaceVersionNotFoundException`. Exposed `_tmatch.version` in playbook scope.

## Next session should

1. Run `work continue` — #962 (`pos-morphological-generation`) is the next active item
2. The qhorus side of version safety (storing version in commitment metadata, passing at resolution time) is a separate qhorus change — not a platform issue
3. Template-registry modules (`template-registry-api`, `template-registry`, `template-registry-llm`) are not yet documented in CLAUDE.md — worth adding when next touching those modules

## References

- Spec: `docs/specs/issue-972-atomic-namespace-version/2026-11-27-atomic-namespace-version-design.md`
- Plan: `plans/2026-11-27-atomic-namespace-version.md`
- Diary: `docs/blog/2026-11-27-mdp01-closing-the-registry-loop.md`
- Decisions: `docs/specs/issue-972-atomic-namespace-version/decisions.md`
