# Decisions — Issue #959: Unified Template Registry

## D1: Discrimination tree structure

**Choice:** Lemma trie — positional trie where nodes are lemmas at specific template positions. Variable slots are wildcard branches. Input tokens walk the tree, pruning candidates at each step. O(template depth) lookup.
**Alternatives:**
- Inverted lemma index — simpler but less positional discrimination, doesn't improve much over existing keyword affinity filtering
- Hybrid (inverted index + positional verification) — best of both but more complexity for marginal gain
**Rationale:** Positional trie gives precise discrimination. Aligns with the existing datasource-alpha Rete pattern (TypeNode/FilterNode). The tree is built from lemmatised literal segments of each template — variable positions are wildcards.
**Trade-offs:** More complex to implement than a flat inverted index. Tree must be rebuilt when templates are registered/deregistered.
**Sources:** datasource-alpha module (AlphaDataSource, TypeNode, FilterNode), ProtocolEvaluator keyword scoping
**Exploration:** quick
**Status:** captured

## D2: NLP generation model

**Choice:** Layered resolution with value-carried metadata — template authoring stays as simple `${var}` syntax. Generation does its best with what's available: (1) POS structure from compiled template drives verb conjugation and determiner agreement automatically, (2) optional metadata on values provides pronoun/gender/number hints for target entities, (3) no metadata → canonical/neutral forms. Graceful degradation, not all-or-nothing.
**Alternatives:**
- Template-declared metadata (`${agent:3rd-singular}`) — heavier authoring, explicit but verbose
- Simple substitution (no grammar adaptation) — doesn't fulfil bidirectional promise
- Mandatory metadata (all-or-nothing) — rejects generation without full context
**Rationale:** Keeps template authoring simple. The NLP pipeline already knows each literal's POS role; metadata supplements what it can't infer. Layered resolution means partial metadata is still useful — a caller providing number but not gender still gets verb agreement right.
**Trade-offs:** Morphological rules are language-specific (English only for now). Output quality scales with metadata completeness — consumers that skip metadata get correct but less natural output.
**Sources:** OpenNlpTokenizer (POS tagging, lemmatisation), StructuralPattern (POS-anchored matching)
**Exploration:** quick
**Status:** captured

## D3: Template type model in the registry

**Choice:** Single type, regex as automatic fast-path — all templates are NLP templates internally. When input matches exactly (all literals match as tokens), it's effectively a regex match (score 1.0). The consumer registers templates without choosing a matching strategy. The discrimination tree handles both cases transparently.
**Alternatives:**
- Explicit template types (RegexTemplate vs NlpTemplate) — consumer controls strategy, more complex API
- Auto-detect with override — middle ground, still exposes the distinction
**Rationale:** Eliminates the consumer's need to understand the internal matching strategy. A template is a template — the registry picks the best path. Regex matches fall out naturally from the NLP pipeline when all literals match exactly. Simplest possible API surface.
**Trade-offs:** Performance of "simple" templates goes through NLP compilation (tokenise + POS tag) at registration time, even if they'd work fine with just regex. This is a one-time cost at registration, not per-match.
**Sources:** TwoTierMessageMatcher two-tier pattern, ProtocolEvaluator's existing regex-first fallback
**Exploration:** quick
**Status:** captured

## D4: Module relationship — template-registry-api supersedes message-extraction-api

**Choice:** template-registry-api absorbs the useful types from message-extraction-api (VariableConstraint, NlpTokenizer, AnnotatedToken). message-extraction-api is retired. RegexMessageMatcher's compilation logic is replaced by the registry's internal matching. Similarly, template-registry (impl) absorbs message-extraction's NLP code (StructuralPattern, TwoTierMessageMatcher's matching logic, OpenNlpTokenizer).
**Alternatives:**
- Depend on message-extraction-api — keeps it alive but was designed for a different model (MessageSchema/MessageType vs registry)
- Coexist independently — maximum independence but ongoing duplication
**Rationale:** Single source of truth. The two stacks (protocol and extraction) were parallel implementations of the same concept. Unifying eliminates the duplication.
**Trade-offs:** Breaking change for any consumers of message-extraction-api. If absorption doesn't work cleanly, we may need to keep message-extraction-api as a compatibility shim temporarily. Design should allow graceful fallback.
**Sources:** message-extraction-api (VariableConstraint, NlpTokenizer, AnnotatedToken, MessageMatcher), message-extraction (TwoTierMessageMatcher, StructuralPattern, OpenNlpTokenizer)
**Exploration:** quick
**Depends on:** D3 (single template type means no need for separate regex/NLP module split)
**Status:** captured
