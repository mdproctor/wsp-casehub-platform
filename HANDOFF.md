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

Position 10/10. **All items complete.**

### Completed across all sessions
| # | Item | Session |
|---|------|---------|
| #9004 | Update tests for faultAddress removal | Phase 2 |
| #9005 | Update docs for deleted classes | Phase 2 |
| #9006 | Fix K8s Optional<CaseInstance> error | Phase 2 |
| #9002 | WebClient → JDK HttpClient (4 modules) | Phase 2 |
| #9000 | Per-module -core extraction (6 modules) | Phase 3 (this session) |
| #9001 | MCP -core extraction (deliberate design) | Phase 3 (this session) |
| #9003 | Consolidated workers-spring auto-config | Phase 3 (this session) |
| casehub-worker#16 | Spring Boot deployment | Prior slot work |
| blocks#297 | Spring Boot deployment | Prior slot work |
| workers#24 | Spring Boot deployment | Phase 1–3 |

## What's Next

Follow-up items not covered by this slot's scope:

| Item | Scale | Complexity | Notes |
|------|-------|-----------|-------|
| Workers CLAUDE.md update | S | Low | Module table needs all 7 new -core modules + workers-spring |
| Workers docs update | S | Low | Contributor guide needs new module architecture |
| Workers spring-integration-test | M | Med | Like platform's spring-integration-test — verify all auto-configs compose |
| MCP Spring session provider | M | Med | JDK HttpClient implementation of McpSessionProvider for Spring Boot |
| K8s Spring completion | M | High | Spring equivalents for Runtime/ExecutionManager — needs fabric8 Spring integration |

## Slot State

All 8 repos complete. Workers repo has 21 commits on `issue-24-spring-boot-deployment` (not yet merged).

| Repo | Spring Status | Branch |
|------|--------------|--------|
| platform | Complete | — |
| engine | Complete | — |
| work | Complete | — |
| qhorus | Complete | — |
| neocortex | Complete | — |
| ledger | Complete | — |
| casehub-worker | Complete | `issue-16-spring-boot-deployment` (not yet merged) |
| blocks | Complete | `issue-297-spring-coverage-expansion` (not yet merged) |
| **workers** | **Complete** | `issue-24-spring-boot-deployment` (21 commits, not yet merged) |
