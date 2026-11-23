# HANDOFF — casehub-platform

**Last worked:** #934 (RoutingAgentProvider default backend fallback) — landed on main.
**Branch:** `issue-936-seed-catalog-instanceid` — scaffolded, no work started.
**Active item:** #936 (seed-catalog instanceId field mismatch).

## Session summary

Landed #934 — two compounding bugs that prevented containerised deployments from invoking any LLM model. ModelDescriptor `apiModelId` now defaults to `id` when null; RoutingAgentProvider falls back to default backend when all resolution steps fail.

Filed #935 (authn-social-jpa classpath failure, pre-existing) and #936 (seed-catalog instanceId mismatch, same root cause area as #934). #936 was prioritised because the context from #934 is still fresh.

## What to do

**#936 is a one-line fix.** The seed catalog YAML uses field name `instanceId` but `ModelDescriptor` has `backendInstanceId`. Jackson silently drops the value. `SeedCatalogModelSource` handles it manually (line 75), but the `AgentManifestLoader` Jackson path doesn't.

**Recommended fix:** Add `@JsonAlias("instanceId")` on the `backendInstanceId` record component in `ModelDescriptor`. This accepts both names without breaking existing code. File: `platform-api/src/main/java/io/casehub/platform/api/model/ModelDescriptor.java`.

**Test:** Construct a `ModelDescriptor` via Jackson with `instanceId` in the YAML and assert `backendInstanceId()` is populated.

## Queue state

| # | Issue | Status |
|---|-------|--------|
| #934 | RoutingAgentProvider default backend fallback | done, landed |
| #936 | seed-catalog instanceId mismatch | active — scaffolded |
| #935 | authn-social-jpa classpath failure | deferred (different domain) |

## Deferred

- ts-core TsjTsExecutor JVM-native TS execution (XS/Low)
