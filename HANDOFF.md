# HANDOFF — casehub-platform

**Last worked:** #934 (RoutingAgentProvider default backend fallback) — done, landing.
**Branch:** `issue-934-comprehensive-review-audit` — squashed to 1 commit, ready to land.
**Active item:** none — #935 and #936 queued.

## Session summary

Single-issue session — #934 fixed two compounding bugs that prevented containerised deployments from invoking any LLM model.

**Bug 1 — ModelDescriptor apiModelId:** `Objects.requireNonNull(apiModelId)` in the compact constructor throws when Jackson deserialises seed-catalog.yaml entries that omit `apiModelId`. The manual parser in `SeedCatalogModelSource` defaults to `id`, but the Jackson path in `AgentManifestLoader` doesn't. Fixed by defaulting `apiModelId` to `id` when null.

**Bug 2 — RoutingAgentProvider fallback:** `resolve()` throws `IllegalArgumentException` when all four resolution steps fail, without checking `defaultBackendKey`. Added a Step 4 fallback to the default backend with a warning log. Uses `allowDefaultFallback` parameter (`false` for chain entries) to preserve chain exhaustion semantics.

**Code review:** Clean — zero findings. 1,012 tests pass across platform-api, agent-router-core, agent-router.

**Filed:** #935 (authn-social-jpa classpath failure, pre-existing), #936 (seed-catalog instanceId field mismatch, latent).

## Queue state

| # | Issue | Status |
|---|-------|--------|
| #934 | RoutingAgentProvider default backend fallback | done, landing |
| #935 | authn-social-jpa classpath failure | queued |
| #936 | seed-catalog instanceId mismatch | queued |

## Attention for next session

1. **#935 is next** — `AbstractStaticCredentialStoreTest` not on classpath in `authn-social-jpa`. Pre-existing, XS/Low.
2. **#936** — `instanceId` YAML field silently lost by Jackson deserialization. Same root cause area as #934. XS/Low. Option 2 (`@JsonAlias`) is safest.
