# HANDOFF — casehub-platform

**Last worked:** #974 — corpus quality testing (done, awaiting landing)
**Branch:** `issue-974-corpus-quality-testing`
**Previous session landed:** #986, #987, #979

## This session

### #974 — Corpus quality testing (implemented + done)

Designed, planned, and implemented the two-mode quality harness for template corpora. 9 commits on this branch.

**What was built:**
- `VariationResult`, `TemplateReport`, `CorpusQualityReport` — report records in `template-registry-api`
- `VariationFixture`, `VariationFixtureLoader`, `VariationFixtureWriter` — YAML fixture format with Jackson
- `CorpusQualityHarness` — evaluates fixtures with field validation + cross-namespace collision detection
- `CorpusVariationGenerator` — CLI tool in `template-registry-llm` for LLM-mode quality evaluation
- `CorpusQualityGateTest` — parameterized JUnit CI quality gate
- `CorpusQualityOllamaIT` — Ollama integration test (gated by `@EnabledIfSystemProperty`)
- `.github/workflows/corpus-quality.yml` — scheduled/manual Ollama workflow

**Code review findings addressed:** stream leak in quality gate test, fragile JSON parsing in OllamaDirectChatModel replaced with Jackson.

**Filed:** #999 — `matchStructural(namespace, input)` overload needed for deterministic collision detection with LLM-backed registries. Currently collision detection uses `match(otherNs, input)` which could include LLM fallback on `AdaptiveTemplateRegistry`.

**Jackson dependency note:** `template-registry-api` now depends on `jackson-databind` + `jackson-dataformat-yaml` (compile scope) for the fixture loader/writer. Previously zero-dep beyond `yaml-core`.

## Next session should

1. Run `work end` to land #974 and advance to next issue
2. Next in queue: #969 — YAML corpus format for template registry
3. After that: #970 — match playbook step with type-safe variable flow, #999 — matchStructural namespace overload

## References

- Plan: `/Users/mdproctor/claude/public/casehub/platform/plans/2026-11-26-corpus-quality-testing.md`
- Spec: `/Users/mdproctor/claude/public/casehub/work/specs/issue-974-corpus-quality-testing/2026-11-26-corpus-quality-testing-design.md`
- Diary: `blog/2026-11-26-mdp06-corpus-quality-harness.md`
- Key new files: `template-registry-api/.../CorpusQualityHarness.java`, `template-registry-llm/.../CorpusVariationGenerator.java`
