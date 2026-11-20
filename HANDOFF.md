# HANDOFF — casehub-platform

**Last worked:** #921 done on branch `issue-921-template-variable-extraction`.
**Branch:** `issue-921-template-variable-extraction` (from main). Marked done, not yet landed.
**Queue:** #915 is next (restore StepRunner pipeline coverage)

## Session summary

Single-issue session — template-based variable extraction from prose (#921, S/Med).

**#921 (S/Med) — feat:** `TemplateExtractor` and `TemplateRegistry` in `io.casehub.yaml.core.resolver` (yaml-core). Compiles `${variable}` templates into named-group regex patterns for deterministic extraction of structured data from agent prose. Lazy `.+?` matching between variables, greedy `.+` for the last. `TemplateRegistry` provides ordered multi-template matching. 29 tests. Code review hardened: compile-time validation of variable names (regex group constraints + duplicate rejection), unmodifiable result maps.

**Blog:** "The Template That Reads the Room" — governance protocol vocabulary via template extraction.

**Filed:** #923 (optional segments in TemplateExtractor, S/Med), #924 (governance protocol runtime integration, M/Med), #925 (dotted variable name support, S/Low). All three scheduled in queue.

## Branches to land

1. `issue-921-template-variable-extraction` — from main, 2 commits

## Queue state

| # | Issue | Status |
|---|-------|--------|
| #921 | template-variable-extraction | done, not landed |
| #915 | restore-StepRunner-pipeline-coverage | next |
| #916 | Spring-REST-authn-endpoints | queued |
| #913 | Spring-parity-mcp-server | queued |
| #917 | Spring-parity-CredentialRetentionPurge | queued |
| #918 | Contract-test-WorkerCredentialStore | queued |
| #919 | Spring-contract-StaticCredentialStore | queued |
| #923 | optional-segments-TemplateExtractor | queued |
| #924 | governance-protocol-integration | queued |
| #925 | dotted-variable-names-TemplateExtractor | queued |

## Attention for next session

1. **One branch needs landing** — `issue-921-template-variable-extraction` (2 commits, from main).
2. **#915 is next** — test restoration in yaml-test-core, different domain from template extraction. Fresh session context is fine.
3. **Three new issues filed this session** — #923, #924, #925 are template extraction follow-ups, all queued at the end.
