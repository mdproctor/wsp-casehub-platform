# HANDOFF — Slot 198

## Last Session

Workers#24 Phase 3 — complete core extraction for all 6 remaining modules, MCP SPI design, consolidated Spring auto-configuration. 8 commits on branch `issue-24-spring-boot-deployment` in the workers repo.

### What was built

1. **workers-github-actions-core** (commit 00d8111) — 4 POJO classes. GitHubActionsTokenResolver (constructor-injected config), GitHubActionsWorkerRuntime, GitHubActionsWorkerExecutionManager (JDK HttpClient). All tests moved. Workers-github-actions slimmed to GitHubActionsWorkerBeans.

2. **workers-http-core** (commit 7c540ce) — 7 classes. ExchangeMode, HttpWorkerConstants, HttpWorkerRoute, ResolvedEndpoint (pure types) + HttpEndpointResolver, HttpWorkerRuntime, HttpWorkerExecutionManager (POJO conversion). 3-tier endpoint resolution preserved. HttpWorkerBeans in Quarkus module.

3. **workers-camel-core** (commit 1d44ae0) — 2 classes (CamelWorkerConstants, CamelExchangeWorkerFunction). Minimal extraction — ProducerTemplate-coupled classes stay in workers-camel.

4. **workers-scenario-core** (commit 296c724) — 5 POJO classes. ScenarioEndpointResolver (config loading moved to Beans), ScenarioWorkerRuntime (removed initializeFromConfig() call), ScenarioWorkerExecutionManager (constructor-injected). All tests moved.

5. **workers-k8s-core** (commit cf50eaa) — 4 classes. K8sWorkerConstants, CleanupPolicy, JobDefinition (pure types) + JobDefinitionResolver (7-param constructor for defaults, buildFromConfig() kept as public for Beans). Runtime/ExecutionManager/JobBuilder/OutputCapture/InformerManager stay (fabric8-coupled). K8sWorkerBeans added.

6. **workers-mcp-core** (commit d10f373) — 7 classes including **McpSessionProvider SPI** (the design contribution). McpWorkerConstants, ResolvedMcpServer, McpSession, ServerInitResult (pure types) + McpServerResolver (POJO) + McpWorkerExecutionManager (takes McpSessionProvider instead of McpSessionManager). McpSessionManager implements McpSessionProvider (bridges Uni→blocking). McpWorkerRuntime stays (Vert.x WebClient for tools/list).

7. **workers-spring** (commit b936c0b) — 6 auto-configuration classes. WorkersCommonAutoConfiguration (lifecycle orchestrator, fault/completion publishers with ApplicationEventPublisher bridging). Per-worker auto-configs with @ConditionalOnClass guards. MCP guarded on @ConditionalOnBean(McpSessionProvider.class).

### Consistent extraction pattern

All modules follow the same pattern:
- CDI annotations removed, constructor injection for all deps
- `org.jboss.logging.Logger` → `java.util.logging.Logger`
- `@Produces` Beans class in each Quarkus module
- All tests moved to -core with constructor injection updates
- quarkus-vertx and smallrye-mutiny-vertx-web-client removed where no longer needed

## Queue State

Position 10/10. **All planned items complete.** 8 verified remaining items below.

## What's Next — Verified Against Code

### Workers repo (on branch `issue-24-spring-boot-deployment`)

| # | Item | Scale | Complexity | Verified status |
|---|------|-------|-----------|-----------------|
| 1 | Workers CLAUDE.md update | S | Low | Module table lists old modules only — 7 new -core modules + workers-spring missing |
| 2 | Workers docs update | S | Low | `docs/guides/` exists but not updated for new module architecture |
| 3 | Workers spring-integration-test | M | Med | Module does not exist — needs creating like platform's spring-integration-test |
| 4 | MCP Spring session provider | M | Med | Auto-config references McpSessionProvider but no Spring implementation exists |
| 5 | K8s Spring completion | M | High | K8s Runtime/ExecutionManager not in Spring auto-config (fabric8-coupled) |

### Branch merges (3 repos with unmerged branches)

| # | Item | Scale | Notes |
|---|------|-------|-------|
| 6 | Merge casehub-worker#16 | XS | Branch `issue-16-spring-boot-deployment` — still on branch, not on main |
| 7 | Merge blocks#297 | XS | Branch `issue-297-spring-coverage-expansion` — still on branch, not on main |
| 8 | Merge workers#24 | XS | Branch `issue-24-spring-boot-deployment` — 21 commits, not on main |

### Already done (close these GitHub issues)

| Item | Evidence |
|------|----------|
| ~~Port ledger Panache→JPA~~ (`casehubio/ledger#208`) | 0 Panache files found in ledger |
| ~~Port work Panache→JPA~~ (`casehubio/work#401`) | 0 Panache files found in work |
| ~~Port qhorus Panache→JPA~~ (`casehubio/qhorus#440`) | 0 Panache files found in qhorus |

### Platform sync (not a feature item — infrastructure)

| Item | Notes |
|------|-------|
| Platform project push to origin | origin/main diverged 21 commits — needs rebase with MCP test file conflict resolution |

## Slot State

All 8 repos have Spring work complete. 3 branches unmerged.

| Repo | Spring Status | Branch |
|------|--------------|--------|
| platform | Complete | — (push to origin pending) |
| engine | Complete | — |
| work | Complete | — |
| qhorus | Complete | — |
| neocortex | Complete | — |
| ledger | Complete | — |
| casehub-worker | Complete | `issue-16-spring-boot-deployment` (not yet merged) |
| blocks | Complete | `issue-297-spring-coverage-expansion` (not yet merged) |
| **workers** | **Complete** | `issue-24-spring-boot-deployment` (21 commits, not yet merged) |
