## D1: Activation model

**Choice:** Adaptive threshold — bag-of-words below N templates per namespace, trie above
**Alternatives:**
- Always trie — simpler code path but trie construction overhead for small registries
- Explicit opt-in — constructor flag, most flexible but pushes decision to consumers
**Rationale:** The trie's O(depth) advantage only pays off at scale. Small registries (10-50 templates) don't benefit and shouldn't pay construction cost.
**Trade-offs:** Two code paths to maintain (bag-of-words + trie). Threshold value needs tuning.
**Sources:** Issue #964 body ("asymptotic advantage only pays off at hundreds of templates")
**Exploration:** quick
**Status:** captured

## D2: Leading variable handling

**Choice:** Wildcard root node — templates starting with a variable get a wildcard entry at the trie root, discriminating on later literals
**Alternatives:**
- Exclude from trie — leading-variable templates fall back to bag-of-words scan
- Index on first non-variable literal — loses positional discrimination
**Rationale:** Wildcard root preserves the trie's ability to discriminate on structural position. Skip nodes are already needed for mid-template variables.
**Trade-offs:** Some fan-out at the root for wildcard-prefixed templates. But later literals still narrow effectively.
**Sources:** StructuralMatcher element structure — CLAUSE elements at position 0
**Exploration:** quick
**Status:** captured

## D3: Trie + embedding rescue interaction

**Choice:** Independent — trie is a standalone candidate-selection strategy in NlpTemplateRegistry. Embedding rescue stays in AdaptiveTemplateRegistry. No speculative integration.
**Alternatives:**
- Trie replaces affinity gate only, non-candidates get embedding rescue — defeats trie's performance purpose (O(T×P) embedding checks on rejected patterns)
- Trie disables embedding rescue — simpler but loses coverage for large registries
**Rationale:** The trie and embedding rescue serve different purposes (performance vs vocabulary coverage). Designing their interaction without evidence of needing both simultaneously is speculative. The LLM fallback tier still catches synonym gaps.
**Trade-offs:** If a large registry has significant synonym gap problems, embedding rescue won't help when the trie is active. The LLM tier handles this but at higher cost.
**Sources:** #982 implementation — embedding rescue analysis, structural matcher limitations with synonym gaps
**Exploration:** deep-analysis
**Status:** captured

## D4: Trie data structure

**Choice:** Explicit node tree — LiteralNode + WildcardNode objects, immutable after construction
**Alternatives:**
- Flattened array trie — cache-friendly but complex to implement, premature for ~100-500 templates
- Layered filter chain — per-position maps, simpler but loses structural awareness of variable slots
**Rationale:** Clear, debuggable, testable. Memory proportional to unique element paths. Rebuild is microseconds at target scale.
**Trade-offs:** Slightly more memory than a flattened array. Not cache-optimal. Acceptable at the stated scale.
**Sources:** Standard trie literature, StructuralMatcher.Element for node types
**Exploration:** quick
**Status:** captured

## D5: Trie walk strategy

**Choice:** Scan-ahead for next literal — at wildcard nodes, scan remaining input tokens for children's literal lemmas. Branch depth-first (shortest skip first) if multiple children match.
**Depends on:** D4 (explicit node tree)
**Alternatives:**
- Fixed skip (1 token) — wrong for multi-word clause captures
- Bounded window (N tokens) — arbitrary cutoff misses long captures
**Rationale:** Mirrors StructuralMatcher.captureClause() semantics. Branching factor is bounded by distinct next-literals across shared prefixes (typically 2-5).
**Trade-offs:** Not O(1) per wildcard node — scan is O(remaining tokens × branching factor). Still much faster than O(T×P) full scan.
**Sources:** StructuralMatcher.captureClause() implementation
**Exploration:** quick
**Status:** captured

## D6: Module and integration

**Choice:** Trie lives in template-registry module. Inline strategy selection in matchInNamespace() — template count check selects bag-of-words loop or trie path. Per-namespace trie stored alongside nlpCompiled, rebuilt on register/deregister/replace.
**Depends on:** D1 (adaptive threshold), D4 (explicit node tree)
**Alternatives:**
- New template-registry-trie module — clean boundary but unnecessary module proliferation
- CandidateSelector interface — extra abstraction for a binary count-based choice (YAGNI)
**Rationale:** The trie is a pure NLP/structural optimization with no external dependencies. AdaptiveTemplateRegistry inherits the benefit through its matchInNamespace() override.
**Trade-offs:** matchInNamespace() gains a strategy branch. Two code paths in one method. Acceptable for the clarity gained vs abstraction overhead.
**Sources:** NlpTemplateRegistry architecture, template-registry module boundary
**Exploration:** quick
**Status:** captured
