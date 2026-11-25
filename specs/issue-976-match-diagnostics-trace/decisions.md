## D1: Trace API activation pattern

**Choice:** Separate `matchWithTrace()` methods on `UnifiedTemplateRegistry`
**Alternatives:**
- Mutable collector parameter — reuses existing method but side-effects are less idiomatic for records-heavy API
**Rationale:** Zero overhead on the hot path — existing `match()` is completely untouched. Return type (`MatchTraceResult`) composes the match result with trace data cleanly.
**Trade-offs:** Two parallel method families to maintain (match + matchWithTrace)
**Sources:** `UnifiedTemplateRegistry.java`, `InMemoryTemplateRegistry.java`, `NlpTemplateRegistry.java`
**Exploration:** quick
**Status:** captured

## D2: Trace data granularity

**Choice:** Full pipeline trace — per-template candidate with keyword affinity, match outcome, per-element walk, and score
**Alternatives:**
- Summary only — simpler but can't explain which literal or constraint failed
- Full + constraint detail — adds specific constraint rejection info (e.g. "enum 'maybe' not in [approve, reject]"); deferred — can be added later without breaking the trace shape
**Rationale:** The whole point is explaining *why* templates don't match. Per-element walk is the minimum data to answer that question. Keyword affinity explains why candidates were filtered before structural matching even ran.
**Trade-offs:** More data to collect in the trace path; trace objects are heavier
**Sources:** `StructuralMatcher.java` (per-element walk), `LemmatisedKeywordFilter.java` (affinity), `CompiledTemplate.java` (regex extraction)
**Exploration:** quick
**Status:** captured

## D3: Module placement

**Choice:** `template-registry-api` — alongside existing types
**Alternatives:**
- Separate `template-registry-trace` module — adds dependency management overhead for minimal size benefit
**Rationale:** Trace types are part of the registry SPI contract. Consumers already depend on `template-registry-api` for `UnifiedTemplateRegistry` and `TemplateMatch`. Adding trace types here means zero new dependencies.
**Trade-offs:** Slightly larger API module
**Sources:** `template-registry-api/` module structure
**Exploration:** quick
**Status:** captured
