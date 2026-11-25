# HANDOFF — casehub-platform

**Last worked:** #959 (unified template registry) — complete, landing.
**Branch:** `issue-959-unified-template-registry` (squashed: 15 → 6 commits)
**Active item:** #959 — done, closing.

## Session summary

Built the unified template registry — two new modules replacing the fragmented template matching infrastructure. 10 design decisions validated, full implementation with 67 integration tests proving NLP normalisation, variable extraction, function/event mapping, pronouns, singular/plural handling, and comma-separated list capture.

### What was built

**template-registry-api** (zero-dep Declaration Primitive):
- Core types, UnifiedTemplateRegistry SPI, regex compilation/matching, template slot-filling generation, InMemoryTemplateRegistry with immutable-snapshot concurrency

**template-registry** (L4 Extension, OpenNLP):
- OpenNlpTokenizer, LemmatisedKeywordFilter, StructuralMatcher, NlpTemplateRegistry with two-tier matching, @McpDomain TemplateSchemaEndpoint

**platform-core**: NoOpUnifiedTemplateRegistry @DefaultBean

## Queue — next session

| # | Issue | Scale | Complexity |
|---|-------|-------|------------|
| #969 | YAML corpus format for template registry | S | Med |
| #970 | match playbook step with type-safe variable flow | M | High |
| #967 | atomic namespace replace | XS | Low |
