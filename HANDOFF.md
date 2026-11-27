# HANDOFF — casehub-platform

**Last worked:** #982 — statistical goodness-of-fit filter (branch created, not started)
**Branch:** `issue-982-goodness-of-fit-filter`
**This session landed:** #961, #972

## This session

Landed two issues under epic #943 (unified template registry):

- **#961:** Consumer migration — moved PlaybookRunnerCore to UnifiedTemplateRegistry, deleted ProtocolEvaluator stack + message-extraction modules (~2,500 lines)
- **#972:** Version safety — monotonic version on TemplateNamespace, bounded history ring in Snapshot, version-pinned match() overload

Created branch for #982 but did not start brainstorming — topic change to NLP/statistical grammar warrants a fresh session.

## Next session should

1. Run `work continue` — #982 is active on `issue-982-goodness-of-fit-filter`
2. Start with brainstorming — M-scale, complexity High, design questions about statistical grammar approach
3. Note: issue #982 body references `ProtocolEvaluator.scopeCandidates()` which was deleted in #961 — only `NlpTemplateRegistry.matchInNamespace()` remains as the active call site for keyword filtering
4. `LemmatisedKeywordFilter` in `template-registry` is the class to replace/augment

## References

- Issue: casehubio/platform#982
- Key file: `template-registry/src/main/java/io/casehub/template/registry/nlp/LemmatisedKeywordFilter.java`
- Key file: `template-registry/src/main/java/io/casehub/template/registry/nlp/NlpTemplateRegistry.java`
