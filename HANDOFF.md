# HANDOFF — casehub-platform

**Last worked:** #982 + #964 — embedding rescue tier and positional discrimination trie (implementation complete, landing next)
**Branch:** `issue-964-positional-discrimination-trie` (stacked on `issue-982-goodness-of-fit-filter`)
**This session landed:** nothing (work-end in progress)

## This session

Implemented two features for the template matching pipeline:

- **#982 (M/High):** Embedding rescue tier — four-tier cascade (regex → keyword affinity → embedding similarity → LLM). `AdaptiveTemplateRegistry` overrides `matchInNamespace()` for per-pattern embedding rescue. Synonym learning feeds back into keyword affinity. `ClassificationCache` extended for embedding results. 8 commits, 1,173 lines.
- **#964 (S/Med):** Positional discrimination trie — `DiscriminationTrie` with literal + wildcard nodes for O(depth) candidate selection. Threshold activation at 100 patterns per namespace. Integrated into `NlpTemplateRegistry.matchInNamespace()`. 3 commits, 506 lines.
- **Code review:** 1 Critical finding (embedding cache key scope) + 4 Important findings fixed. Diary entry written.

## Next session should

1. Run `work end` — both issues are done on their branches, squash reviews recorded, ready to land
2. After landing, #965 (multi-language-nlp-tokenizers) is next in queue — not yet started, needs brainstorming

## Key decisions to know

- **Trie + embedding rescue are independent.** Trie is in NlpTemplateRegistry (base), embedding rescue is in AdaptiveTemplateRegistry (subclass). No pre-engineered interaction — LLM fallback tier catches what both miss.
- **Trie skips optional literals during build** to maintain equivalence with bag-of-words path.
- **Embedding cache removed from inner loop** — the per-namespace cache key caused false negatives across templates. Input embedding is computed once per match via local variable.
- **Synonym learning threshold:** 0.7 cosine similarity for per-word synonym pairs; 0.5 for overall embedding rescue gate.

## Queue state

- #982 — done on branch, awaiting landing
- #964 — done on branch, awaiting landing
- #965 — multi-language-nlp-tokenizers — next, not started
- #963 — icu-messageformat-2 — queued
