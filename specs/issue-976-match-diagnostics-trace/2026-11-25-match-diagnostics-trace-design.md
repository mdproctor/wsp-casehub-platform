# Match Diagnostics Trace API

**Issue:** #976  
**Parent:** #959 (unified template registry)  
**Branch:** issue-976-match-diagnostics-trace

## Problem

When a template fails to match, the author gets `Unmatched(input)` — the string they already had. No information about which templates were considered, which structural element failed, or how close the best candidate was. The debugging cycle is guess-and-retry, which drives people toward hard-coded regex patterns.

## Design

### API Surface

Add `matchWithTrace()` to `UnifiedTemplateRegistry`:

```java
// Existing — untouched
TemplateMatch match(String input);
TemplateMatch match(String namespaceName, String input);

// New — diagnostics variant
MatchTraceResult matchWithTrace(String input);
MatchTraceResult matchWithTrace(String namespaceName, String input);
```

Zero overhead on the hot path. `match()` is completely unchanged.

### Trace Data Model

All types in `template-registry-api`, package `io.casehub.template.registry`.

```java
record MatchTraceResult(
    TemplateMatch result,
    MatchTrace trace
) {}

record MatchTrace(
    List<CandidateTrace> candidates,
    String bestCandidate,   // "namespace:templateName" or null
    double bestScore        // 0.0 if no candidates scored
) {}

record CandidateTrace(
    String namespace,
    String templateName,
    int patternIndex,
    double keywordAffinity, // -1.0 for regex tier (no keyword filtering)
    CandidateOutcome outcome,
    List<ElementTrace> elements,  // empty for regex tier
    double score                  // 0.0 if not scored
) {}

record ElementTrace(
    ElementKind kind,       // LITERAL, VARIABLE, CLAUSE
    String expected,        // lemma or variable name
    String actual,          // captured value, null if unmatched
    boolean matched
) {}

enum CandidateOutcome {
    MATCHED,
    KEYWORD_FILTERED,
    REGEX_FAILED,
    STRUCTURAL_FAILED,
    CONSTRAINT_FAILED,
    BELOW_THRESHOLD
}

// ElementKind: new top-level enum in template-registry-api
// (StructuralMatcher.ElementKind in template-registry is updated to
// reference this shared type rather than defining its own)
```

### Implementation Layers

#### 1. `StructuralMatcher.matchWithTrace()`

New method alongside existing `match()`. Same algorithm, but collects `ElementTrace` for each element in the walk:

- LITERAL: expected=lemma, actual=input token lemma, matched=lemma equality
- VARIABLE: expected=variable name, actual=captured value, matched=constraint pass
- CLAUSE: expected=variable name, actual=captured clause text, matched=non-blank capture

Returns `TraceableMatchResult(Optional<MatchResult>, List<ElementTrace>)` — always populated regardless of match success.

#### 2. `InMemoryTemplateRegistry.matchInNamespaceWithTrace()`

New protected method. Regex tier — iterates `CompiledTemplate.extract()`:
- Match: `CandidateTrace` with MATCHED, score 1.0, empty elements (regex is opaque)
- No match: `CandidateTrace` with REGEX_FAILED, score 0.0, empty elements

`matchWithTrace(String input)` iterates namespaces, collects all candidates, returns `MatchTraceResult`.

`matchWithTrace(String ns, String input)` scopes to a single namespace.

#### 3. `NlpTemplateRegistry` override

Overrides `matchInNamespaceWithTrace()`. Extends regex candidates with NLP candidates:
- Computes keyword affinity per template/pattern
- Below threshold: `CandidateTrace` with KEYWORD_FILTERED, the affinity score, empty elements
- Above threshold: calls `StructuralMatcher.matchWithTrace()`, wraps as `CandidateTrace` with full element traces
- Below score threshold: BELOW_THRESHOLD with the score
- Match: MATCHED with score and elements

Overrides `matchWithTrace(String input)` to collect cross-namespace best-score (same logic as existing `match()` but with trace accumulation).

### Module Placement

All trace types in `template-registry-api` — same module as `UnifiedTemplateRegistry`, `TemplateMatch`, `TemplateDefinition`. Zero new dependencies.

`StructuralMatcher.matchWithTrace()` and `TraceableMatchResult` in `template-registry` (implementation module).

### What This Doesn't Cover

- No trace on the old `ProtocolEvaluator`/`TemplateMatchingFilter` layer — replaced when #959 completes
- No constraint detail beyond pass/fail (e.g., "enum 'maybe' not in [approve, reject]") — can enrich `ElementTrace` later without breaking the shape
- No persistence or logging of traces — purely a programmatic API for authoring tools

## Testing

1. **Trace types** — construction, null validation, defensive copies
2. **StructuralMatcher.matchWithTrace()** — element traces report which literal failed, which variable captured what, partial match scores
3. **InMemoryTemplateRegistry.matchWithTrace()** — regex MATCHED (score 1.0, empty elements), REGEX_FAILED
4. **NlpTemplateRegistry.matchWithTrace()** — KEYWORD_FILTERED with affinity score, STRUCTURAL_FAILED with element detail, BELOW_THRESHOLD with score, MATCHED cross-namespace best-score
5. **Integration: trace explains failed match** — register template "I ${decision} this design", input "the design looks good to me", assert trace shows: regex failed, keyword affinity passed on "design", structural match failed at literal "I" (expected "i", got "the"), score below threshold

## References

- `UnifiedTemplateRegistry.java` — SPI that gains `matchWithTrace()`
- `InMemoryTemplateRegistry.java:74-96` — `matchInNamespace()` regex walk
- `NlpTemplateRegistry.java:81-122` — `matchInNamespace()` NLP walk
- `StructuralMatcher.java:140-196` — per-element match loop (source of element traces)
- `LemmatisedKeywordFilter.java:63-71` — affinity scoring (source of keyword trace data)
- `CompiledTemplate.java:29-73` — regex extraction (opaque — no element trace possible)
- `TemplateMatch.java` — existing sealed result type
- #959 — parent epic (unified template registry)
- #973 — NearMiss (caller-facing result, not authoring diagnostic)
