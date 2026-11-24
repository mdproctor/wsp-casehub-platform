# HANDOFF — casehub-platform

**Last worked:** #959 (unified template registry) — Batch 1 complete, Batches 2-3 remaining.
**Branch:** `issue-959-unified-template-registry`
**Active item:** #959 — in progress (Batch 1 of 3 done)

## Session summary

Designed and began implementing a unified template registry that replaces the fragmented template matching infrastructure. The existing architecture had two parallel, unconnected stacks (protocol and extraction) with duplicated compilation logic, constraint types, and per-playbook isolated evaluators.

### Design phase

10 decisions captured and validated:
- D1: Lemmatised keyword filtering (not a full discrimination trie — premature for near-term template counts)
- D2: Template slot-filling for generation (not morphological — premature)
- D3: Single template type with regex fast-path; NLP lazy when on classpath
- D4: template-registry-api supersedes message-extraction-api
- D5: Integration test suite as acceptance criterion
- D6: Bidirectionality via slot-filling
- D7: NlpProtocolMatcher retired (zero implementations)
- D8: Schema publication co-located with registration
- D9: Immutable snapshots with AtomicReference CAS
- D10: Module hierarchy (Declaration Primitive + L4 Extension)

Spec: `specs/issue-959-unified-template-registry/2026-11-24-unified-template-registry-design.md`
Plan: `plans/2026-11-24-unified-template-registry.md`

### What was built (Batch 1)

**template-registry-api module** — zero external deps, depends on yaml-core:
- Core types: `TemplateDefinition`, `TemplateNamespace`, `TemplateMatch` (sealed), `TemplateSchema`, `NlpTokenizer` SPI, `AnnotatedToken`
- `UnifiedTemplateRegistry` SPI interface
- `RegexTemplateCompiler` — compiles `${var}` templates to regex (ported from TemplateExtractor)
- `CompiledTemplate` — holds compiled pattern, extracts variables, validates constraints
- `TemplateGenerator` — slot-filling generation (fields → prose), segment-aware optional handling
- `InMemoryTemplateRegistry` — regex-only implementation with immutable-snapshot concurrency
- 53 tests, all passing

Review finding fixed: TemplateSchema variable ordering (Map.copyOf → LinkedHashMap), Snapshot.EMPTY immutability, TemplateGenerator redundant guard.
Filed: #967 (atomic namespace replace — XS/Low).

### What's next (Batches 2-3)

**Batch 2 — NLP tier:**
- Task 3: OpenNlpTokenizer migration + LemmatisedKeywordFilter + StructuralMatcher
- Task 4: NlpTemplateRegistry (two-tier matching with immutable snapshots)

**Batch 3 — Platform integration:**
- Task 5: NoOp @DefaultBean in platform-core + @McpDomain TemplateSchemaEndpoint
- Task 6: Integration test suite (D5 acceptance criterion)

### Follow-up issues filed

- #961 — Consumer migration (ProtocolEvaluator, TemplateMatchingFilter, PlaybookRunnerCore)
- #962 — POS-driven morphological generation
- #963 — ICU MessageFormat 2.0 for multilingual formatting
- #964 — Positional discrimination trie
- #965 — Multi-language NLP support
- #967 — Atomic namespace replace

## Queue state

| # | Issue | Status |
|---|-------|--------|
| #959 | unified template registry | active — Batch 1 done, Batches 2-3 next |
