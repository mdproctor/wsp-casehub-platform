# HANDOFF — casehub-platform

**Last worked:** #949, #976, #973 — NLP template matching observability
**Branches:** `issue-949-nlp-score-preservation` (done), `issue-976-match-diagnostics-trace` (done), `issue-973-nearmiss-guided-rejection` (done, landing)
**Active item:** #967 — atomic namespace replace (next)

## Session summary

Three features closing the gap between "template didn't match" and "here's why and what to try instead." All in the unified template registry layer (`template-registry-api` and `template-registry`).

### What was built

**#949 — NLP score preservation:** `ProtocolMatchResult.Matched` gains `double score` (default 1.0 for regex, explicit for NLP). Propagated through `ProtocolEvaluator` and `TemplateMatchingFilter`. Previously all matches reported 1.0 regardless of actual NLP confidence.

**#976 — Match diagnostics trace API:** `matchWithTrace()` on `UnifiedTemplateRegistry` returns `MatchTraceResult` with full pipeline diagnostics — per-candidate keyword affinity, structural element walk (`ElementTrace`), and `CandidateOutcome` enum. Six new types in `template-registry-api`: `MatchTraceResult`, `MatchTrace`, `CandidateTrace`, `ElementTrace`, `CandidateOutcome`, `ElementKind`. `StructuralMatcher.matchWithTrace()` added with `TraceableMatchResult`. Implementations in `InMemoryTemplateRegistry` (regex tier — opaque) and `NlpTemplateRegistry` (full element traces).

**#973 — NearMiss guided rejection:** `NlpTemplateRegistry.matchInNamespace()` now produces `TemplateMatch.NearMiss` when structural matching scores > 0 but below threshold. `TemplateFormatHelper` utility extracted for format suggestion generation. Cross-namespace NearMiss tracking in `match(String input)`.

### Issues filed

- **#982** — keyword filter improvement (statistical grammar + LLM fallback tiers). Existing bag-of-words filter can incorrectly exclude valid candidates. casehub connectors has statistical grammar integration in STT/TTS.
- **casehubio/qhorus#544** — enforcement pipeline NearMiss wiring via `DispatchAdvisory.evidence` map.

### Code review finding fixed

`StructuralMatcher.matchWithTrace()` had a behavioral divergence from `match()` — set `failed=true` when tokens exhausted instead of allowing partial scores. Fixed to match `match()` behavior (break without failure flag).

## Queue — next session

| # | Issue | Scale | Complexity |
|---|-------|-------|------------|
| #967 | atomic namespace replace | XS | Low |
| #969 | YAML corpus format for template registry | S | Med |
| #970 | match playbook step with type-safe variable flow | M | High |

## Context for next session

- The `NoOpUnifiedTemplateRegistry` in `platform-core` was updated to implement `matchWithTrace()` — returns empty trace with Unmatched.
- `ElementKind` was extracted from `StructuralMatcher`'s inner enum to a shared top-level type in `template-registry-api`. `StructuralMatcher` imports it.
- `CONSTRAINT_FAILED` in `CandidateOutcome` is intentionally unused — reserved for future enrichment of `ElementTrace` with specific constraint rejection detail.
- `matchWithTrace()` runs the regex/NLP pipeline twice (once for result, once for trace). Acceptable for a diagnostics API; noted as a future optimization target.
