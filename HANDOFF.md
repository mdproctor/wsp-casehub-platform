# HANDOFF — casehub-platform

**Last worked:** #919 (blocked) on branch `issue-916-spring-rest-authn-endpoints`.
**Branch:** `issue-916-spring-rest-authn-endpoints` (stacked on `issue-921-template-variable-extraction`).
**Active item:** #923 (optional segments in TemplateExtractor) — not started.

## Session summary

Five-issue session — Spring parity, contract testing, and triage of blocked issues.

**#916 (S/Low) — feat:** Spring REST controllers for three authn domains. Extracted `ConnectionEndpointCore`, `WebAuthnEndpointCore`, `SocialAuthEndpointCore` to `authn-core` with `@McpDomain` and constructor injection. Deleted CDI endpoint classes. `AuthnBeans` now `@Produces` core POJOs. graphql-spring-generator configured in `authn-spring` — generates 6 Spring controllers (3 REST + 3 GraphQL). Key discovery: APT's `getClass().getClassLoader()` reads the annotation processor classpath, not the compilation classpath — `authn-core` had to be added to `annotationProcessorPaths` for Jandex domain discovery.

**#913 (S/Med) — already resolved:** `mcp-server` exception already exists in `spring-parity-exceptions.txt` (commit `a3b60638`, #905).

**#917 (XS/Low) — blocked:** `CredentialRetentionPurge` from #912 hasn't landed on main. Can't mirror what doesn't exist yet. Commented on issue.

**#918 (S/Low) — feat:** `AbstractWorkerCredentialStoreTest` contract test base in `testing` module. 12 tests covering all 6 `WorkerCredentialStore` SPI methods. `InMemoryWorkerCredentialStoreTest` in `acl-inmem-core` extends the base, adds 2 implementation-specific lazy eviction tests (14 total).

**#919 (XS/Low) — blocked:** `AbstractStaticCredentialStoreTest` from #911 hasn't landed on main. Commented on issue.

**Blog:** "The Classloader Nobody Checks" — APT classloader vs compilation classpath for Jandex scanning.

## Branches to land (in order)

1. `issue-921-template-variable-extraction` — from main, 2 commits (#921)
2. `issue-916-spring-rest-authn-endpoints` — stacked on above, 6 commits (#916, #918, code review fix)

## Queue state

| # | Issue | Status |
|---|-------|--------|
| #921 | template-variable-extraction | done on branch 1 |
| #915 | restore-StepRunner-pipeline-coverage | done on branch 1 |
| #916 | Spring-REST-authn-endpoints | done on branch 2 |
| #913 | Spring-parity-mcp-server | done (already resolved) |
| #917 | Spring-parity-CredentialRetentionPurge | done (blocked by #912) |
| #918 | Contract-test-WorkerCredentialStore | done on branch 2 |
| #919 | Spring-contract-StaticCredentialStore | done (blocked by #911) |
| #923 | optional-segments-TemplateExtractor | active, not started |
| #924 | governance-protocol-integration | queued |
| #925 | dotted-variable-names-TemplateExtractor | queued |

## Attention for next session

1. **Two branches need landing in order** — first `issue-921-template-variable-extraction` (from main), then `issue-916-spring-rest-authn-endpoints` (stacked).
2. **#923 is next** — optional segments in TemplateExtractor (yaml-core domain). Fresh session context recommended — different domain from this session's Spring parity work.
3. **Two issues blocked by unlanded work** — #917 (blocked by #912) and #919 (blocked by #911). These will unblock when their respective branches land via work-end.
4. **Pre-existing test failure** — `authn-social-jpa` fails with missing `AbstractStaticCredentialStoreTest` class (from unlanded #911). Not caused by this branch's changes.
