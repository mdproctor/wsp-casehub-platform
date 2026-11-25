## D1: NearMiss production rule

**Choice:** Structural evidence required — NearMiss only when `StructuralMatcher` scored > 0 but below the match threshold (scoreThreshold, default 0.5). Keyword affinity only gates whether structural matching is attempted (unchanged).
**Alternatives:**
- Pure keyword affinity threshold — lacks semantic/structural understanding, fires on bag-of-words overlap even when structure is completely different
- Any structural attempt — too broad, fires even when zero elements matched
**Rationale:** Partial structural score means some elements actually matched the input, giving genuine near-miss evidence. This is structurally grounded, not just lexical similarity.
**Trade-offs:** Slightly fewer NearMiss results than keyword-only approach, but higher quality
**Sources:** `StructuralMatcher.match()` partial scoring, `NlpTemplateRegistry.matchInNamespace()` score threshold
**Exploration:** quick
**Status:** captured

## D2: Enforcement pipeline integration

**Choice:** File a linked qhorus issue for the enforcement wiring. NearMiss data surfaces via the existing `DispatchAdvisory.evidence` map — no new types needed in qhorus.
**Alternatives:**
- Implement in both repos directly — cross-repo in one session adds risk
**Rationale:** `DispatchAdvisory` already has an evidence map. NearMiss guidance (suggestedFormat, suggestedTemplate) goes into this map. The qhorus side is just wiring a playbook step to surface it.
**Trade-offs:** Two PRs instead of one, but cleaner cross-repo boundary
**Sources:** `DispatchAdvisory.java` (qhorus-api), `PlaybookProtocolOutput.java` (playbook-bridge)
**Exploration:** quick
**Status:** captured

## D3: NearMiss suggestedFormat generation

**Choice:** Reuse `TemplateMatchingFilter.formatSuggestion()` pattern — strip optional brackets, replace `${varName}` with `[varName]` for human-readable format. The best-scoring candidate's template pattern is used.
**Alternatives:**
- Raw template pattern — harder for agents/humans to read
**Rationale:** Existing pattern is proven, human-readable, and agent-friendly
**Trade-offs:** None — this is the established pattern
**Sources:** `TemplateMatchingFilter.formatSuggestion()` at yaml-step-runtime
**Exploration:** quick
**Status:** captured
