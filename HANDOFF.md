# HANDOFF — casehub-platform

**Last worked:** #848, #586, #639, #893 landed; #732, #733, #826, #697 closed (already-fixed/not-actionable); #251 deferred; 3 follow-ups filed (#894, #895, #896)
**Landed:** `00fa423b` on main, published
**Queue:** 5 items remaining, #891 is next

## This session

Queue triage + format unification session — eight issues handled, four with code changes.

**#848 (S/Med) — fix:** Streaming plugin factory in `PluginScanner.buildStreamingTypeInfo()` bypassed `coerceParams()` and `Validator.validateStep()`. String-typed numeric fields silently became 0, missing `@Required` fields silently became null. Added coercion + validation + java-typed input checks to match the non-streaming action path. Two new tests: coercion (string "5" → int) and required-field rejection.

**#586 (S/Low) — fix:** Swapped `graphql-spring-generator` test dependency from `platform-api` to `mcp-api`. All test imports were in `io.casehub.platform.api.mcp.*` which lives in the lighter `mcp-api` module. Confirmed by `mcp-standalone-test`'s `bannedDependencies` enforcer.

**#639 (S/Low) — feat:** Added `ModelParameters` record (temperature, maxTokens, topP, topK) with fluent withers, and `withModelParameters()` to both `AgentSessionConfig` and `AgentSessionInit`. All existing withers preserve the new field.

**#893 (S/Med) — fix:** Eliminated `steps:` from every parser path and schema:
- `YamlTestDiscovery` now supports multi-document YAML and rejects top-level `steps:` and `tests:` wrapper
- 14 `.test.yaml` files migrated to bare-list format across 3 modules
- Parallel map form (`parallel: { steps: [...], advance-after: N }`) replaced with sibling keys
- `playbook-document.schema.json` updated: removed `steps:`, `tests:`, `testCase`
- `StepSchemaComposer` generates flat format only

**Already-fixed closures:** #732 (CorpusSelectorService already implemented), #733 (resolvePhaseRecords already supports per-phase corpus-files), #826 (budget types already in agent-api). **Not-actionable:** #697 (no non-Claude multi-turn sessions exist). **Deferred:** #251 (TSJ upstream blocked).

**Filed from code review:** #894 (ModelParameters range validation), #895 (Walker: parallel policy keys only on parallel steps), #896 (YamlTestDiscovery first-doc guard).

**Blog:** "The Key That Wouldn't Die" — format migration that only covered one parser path.

## Queue (5 items)

1. #891 — AgentSessionPlugins absorbs response-format but never reads it ← next
2. #893 — Migrate test yaml from steps wrapper (already landed — stale queue entry)
3. #894 — ModelParameters range validation
4. #895 — Walker parallel key validation
5. #896 — YamlTestDiscovery first-doc guard

## References

- Blog: `blog/2026-11-19-mdp03-the-key-that-wouldnt-die.md`
- Key files: `PluginScanner.java`, `YamlTestDiscovery.java`, `Walker.java`, `ModelParameters.java`, `AgentSessionConfig.java`
