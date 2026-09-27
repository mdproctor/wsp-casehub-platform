# HANDOFF — Slot 198

## Last Session

Workers#24 Phase 2 — test fixes, doc updates, Script core extraction, and complete WebClient→HttpClient migration. 8 commits on branch `issue-24-spring-boot-deployment` in the workers repo.

### What was built

1. **Test fixes** (commit 944db44) — 35 files, -437 net lines. Three categories:
   - EventBus→Consumer: WorkerFaultPublisher, WorkflowCompletionPublisher, WorkerRetrySupport, AsyncWorkerCompletionRegistry tests updated to mock Consumer<T>
   - faultAddress removal: ~60 verify calls fixed across 7 per-module ExecutionManagerTests, PendingCompletion constructors in 10 files
   - void lifecycle: 7 per-module RuntimeTests updated, WorkerFaultHandlerTest fixed for constructor injection
   - Deleted 8 test files (7 FaultEventHandler tests + superseded WorkerLifecycleOrchestratorTest)
   - Fixed pre-existing K8s `Optional<CaseInstance>` compilation error

2. **Doc updates** (commit a9aebc6) — 5 files. CLAUDE.md (14 rows removed, fault pipeline rewritten), contributor-guide, consumer-guide, ARC42STORIES.MD, workers-camel/README.md

3. **workers-script-core module** (commit 09640e8) — New module with 5 POJO classes. ScriptDefinitionResolver (constructor-injected defaults), ScriptWorkerExecutionManager (constructor-injected deps, j.u.l logging), ScriptWorkerRuntime (POJO). workers-script slimmed to ScriptWorkerBeans (@Produces wiring). Removed quarkus-vertx dependency.

4. **WebClient→HttpClient** (commits 1ca3cd3, ec362e3, 0f0dc5a) — Complete. Production code migrated in all 4 modules (HTTP, GitHub Actions, Scenario, MCP). All 4 test files rewritten for JDK HttpClient mocking pattern. D3 mandatory per-request timeout enforced (GitHub Actions had none before).

### WebClient→HttpClient test pattern

All 4 ExecutionManager tests now use:
- Mock `java.net.http.HttpClient` instead of `WebClient`
- `when(httpClient.send(any(), any())).thenReturn(response)` for response stubs
- `HttpHeaders.of(headerMap, (a, b) -> true)` for response headers
- `ArgumentCaptor<HttpRequest>` for URL/header verification via `captured.uri()` and `captured.headers()`
- `httpClient` field is package-private on all ExecutionManagers (settable from tests)

**MCP note:** McpSessionManager still uses Mutiny/WebClient internally — only the ExecutionManager was migrated. McpSessionManagerTest and McpWorkerRuntimeTest still use Vert.x WebClient mocks for the session manager (intentional — full MCP cleanup is #9001).

## Queue State

Position 5/10. Active: #9000 (per-module core extraction). #9002 (WebClient→HttpClient) is complete.

### Completed this session
- #9004: Update tests for faultAddress removal
- #9005: Update docs for deleted classes
- #9006: Fix K8s Optional<CaseInstance> error
- #9002: WebClient→HttpClient (complete — production + all 4 test rewrites)
- workers-script-core extraction (partial #9000)

### Remaining
| # | Item | Status | Notes |
|---|------|--------|-------|
| #9000 | Per-module -core extraction | Script done | HTTP/GH-Actions/Scenario/K8s now unblocked. Camel limited (2 pure types) |
| #9001 | MCP -core extraction | Not started | Deliberate design needed for session mgmt |
| #9003 | Consolidated workers-spring | Blocked | Depends on #9000 + #9001 |

### Per-module core extraction readiness (from survey)

| Module | Pure types | ExecutionManager extractable? | Notes |
|--------|-----------|------------------------------|-------|
| Script | 2 | Done (commit 09640e8) | Full pipeline in core |
| HTTP | 4 | Yes (JDK HttpClient now) | 2 call sites (sync+async) |
| GitHub Actions | 1 | Yes (JDK HttpClient now) | 1 call site |
| Scenario | 2 | Yes (JDK HttpClient now) | 2 call sites (fetch+dispatch) |
| K8s | 3 (+2 fabric8) | Partial (fabric8-coupled) | K8sJobBuilder/OutputCapture are CDI-free but use fabric8 |
| Camel | 2 | No (ProducerTemplate) | Only constants + CamelExchangeWorkerFunction move |

## Slot State

Seven repos complete. Workers Phase 2 in progress.

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
| **workers** | **Phase 2 in progress** | `issue-24-spring-boot-deployment` (13 commits) |
