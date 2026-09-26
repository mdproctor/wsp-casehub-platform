# HANDOFF — Slot 198

## Last Session

Workers#24 Phase 2 progress — test fixes, doc updates, Script core extraction, and WebClient→HttpClient migration (in progress). 6 commits on branch `issue-24-spring-boot-deployment` in the workers repo.

### What was built

1. **Test fixes** (commit 944db44) — 35 files, -437 net lines. Three categories:
   - EventBus→Consumer: WorkerFaultPublisher, WorkflowCompletionPublisher, WorkerRetrySupport, AsyncWorkerCompletionRegistry tests updated to mock Consumer<T>
   - faultAddress removal: ~60 verify calls fixed across 7 per-module ExecutionManagerTests, PendingCompletion constructors in 10 files
   - void lifecycle: 7 per-module RuntimeTests updated, WorkerFaultHandlerTest fixed for constructor injection
   - Deleted 8 test files (7 FaultEventHandler tests + superseded WorkerLifecycleOrchestratorTest)
   - Fixed pre-existing K8s `Optional<CaseInstance>` compilation error

2. **Doc updates** (commit a9aebc6) — 5 files. CLAUDE.md (14 rows removed, fault pipeline rewritten), contributor-guide, consumer-guide, ARC42STORIES.MD, workers-camel/README.md

3. **workers-script-core module** (commit 09640e8) — New module with 5 POJO classes. ScriptDefinitionResolver (constructor-injected defaults), ScriptWorkerExecutionManager (constructor-injected deps, j.u.l logging), ScriptWorkerRuntime (POJO). workers-script slimmed to ScriptWorkerBeans (@Produces wiring). Removed quarkus-vertx dependency.

4. **WebClient→HttpClient** (commits 1ca3cd3 + ec362e3) — Production code complete in all 4 modules (HTTP, GitHub Actions, Scenario, MCP). GitHubActionsWorkerExecutionManagerTest fully rewritten and passing. **3 test files still need rewriting** (see below).

### What's still in progress

**WebClient→HttpClient test rewrites** — 3 test files reference old Vert.x WebClient mocks:
- `workers-http/.../HttpWorkerExecutionManagerTest.java` — 587 lines, most complex (sync+async paths, header verification, body verification)
- `workers-scenario/.../ScenarioWorkerExecutionManagerTest.java` — moderate
- `workers-mcp/.../McpWorkerExecutionManagerTest.java` — moderate (JSON-RPC specific)

The pattern is established by the GitHub Actions rewrite:
- Mock `java.net.http.HttpClient` instead of `WebClient`
- `when(httpClient.send(any(), any())).thenReturn(response)` for response stubs
- `HttpHeaders.of(headerMap, (a, b) -> true)` for response headers
- `ArgumentCaptor<HttpRequest>` for URL/header verification via `captured.uri()` and `captured.headers()`
- `httpClient` field is package-private on all ExecutionManagers (settable from tests)

**MCP note:** McpSessionManager still uses Mutiny/WebClient internally — only the ExecutionManager was migrated. McpSessionManagerTest and McpWorkerRuntimeTest still use Vert.x WebClient mocks for the session manager (intentional — full MCP cleanup is #9001).

## Queue State

Position 5/10. Active: #9000 (per-module core extraction). #9002 (WebClient→HttpClient) is being done first because it unblocks ExecutionManager extraction.

### Completed this session
- #9004: Update tests for faultAddress removal
- #9005: Update docs for deleted classes
- #9006: Fix K8s Optional<CaseInstance> error
- workers-script-core extraction (partial #9000)
- WebClient→HttpClient production code (#9002 production done, 1/4 tests done)

### Remaining
| # | Item | Status |
|---|------|--------|
| #9002 | WebClient→HttpClient | Production done, 3/4 test rewrites remaining |
| #9000 | Per-module -core extraction | Script done; HTTP/Scenario/GH-Actions/K8s need WebClient tests first; Camel limited (2 pure types only) |
| #9001 | MCP -core extraction | Not started — deliberate design needed |
| #9003 | Consolidated workers-spring | Blocked by #9000 + #9001 |

### Analysis from this session

Per-module core extraction is partially blocked by WebClient→HttpClient. Three ExecutionManagers (HTTP, GitHub Actions, Scenario) use Vert.x WebClient and can't move to core until that's replaced. Script was the only module where the full pipeline (ExecutionManager, Resolver, Runtime) could move. Camel is framework-coupled (ProducerTemplate) — only 2 pure types can move.

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
| **workers** | **Phase 2 in progress** | `issue-24-spring-boot-deployment` (10 commits) |
