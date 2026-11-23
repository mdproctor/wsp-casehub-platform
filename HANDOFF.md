# HANDOFF — casehub-platform

**Last worked:** #922 (template-based message extraction) — complete, landing.
**Branch:** `issue-922-template-message-extraction` (stacked on `issue-936-seed-catalog-instanceid`)
**Active item:** #922 — done, closing.

## Session summary

Built two new modules for structured prose extraction — an alternative to JSON for LLM-to-LLM communication where agents speak in prescribed sentence templates and the platform mechanically extracts typed data.

Also fixed #936 (seed-catalog instanceId field mismatch) via Jackson mixin in agent-config-core.

### What was built

**message-extraction-api** (zero-dep):
- Core types: `MessageSchema`, `MessageType`, `VariableConstraint` (sealed: String/Enum), `MessageMatch` (sealed: Matched/Unmatched)
- `RegexMessageMatcher` — compiles templates to regex, extracts variables, validates enum constraints post-match (case-insensitive)
- SPI: `NlpTokenizer`, `AnnotatedToken`
- 22 tests

**message-extraction** (OpenNLP):
- `OpenNlpTokenizer` — tokenization, POS tagging, lemmatization with UD-to-PTB tag mapping for dictionary lookup. Lazy model loading, thread-safe (models shared, ME instances per-call)
- `StructuralPattern` — POS/lemma structural matching with scored coverage
- `TwoTierMessageMatcher` — regex first (score=1.0), NLP fallback (scored coverage)
- 10 tests

### Design decisions

9 decisions captured and reviewed (3 rounds, $44). Key:
- D1: Standalone engine, not coupled to yaml-core
- D2: Two-tier matching — regex first, NLP structural fallback
- D3: NlpTokenizer SPI for pluggable tokenization
- D6: Regex matcher in zero-dep -api module; NLP in -impl

Spec: `docs/specs/issue-922-template-message-extraction/2026-11-23-message-extraction-design.md`

## Queue state

| # | Issue | Status |
|---|-------|--------|
| #936 | seed-catalog instanceId mismatch | done on branch |
| #922 | template-based message extraction | done on branch |
| #942 | move OpenNLP models to Maven/LFS | queued |

## What's next

#942 is a small cleanup (XS/Low) — move bundled OpenNLP model files out of the git repo into a Maven artifact or Git LFS. Filed from code review.
