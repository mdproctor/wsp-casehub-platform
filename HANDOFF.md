# HANDOFF — Slot 198

## Last Session

Completed workers#24 Phase 1 — workers-common-core extraction. Created the new `workers-common-core` module with zero CDI, zero Vert.x dependencies. 5 commits on branch `issue-24-spring-boot-deployment` in the workers repo.

### What was built

1. **workers-common-core module** — 20 framework-neutral Java files. 15 pure types moved (records, enums, exceptions, interfaces) + 5 classes extracted with Consumer<T> replacing EventBus.

2. **WorkerRuntime interface** — changed from `Uni<Void>` to `void`. All 7 per-module implementations updated. Mutiny dependency removed from the interface.

3. **WorkerLifecycleOrchestrator** — extracted to core with parallel virtual thread init. Fixes production bug where sequential `.await().indefinitely()` with no timeout meant a hung MCP server blocks ALL worker initialization. New orchestrator runs all runtimes in parallel with per-runtime timeouts and cancels timed-out futures. 6 tests.

4. **Event pipeline** — 3 EventBus patterns replaced with Consumer<T>:
   - WorkerFaultPublisher: `Consumer<WorkerFaultEvent>` (fire-and-forget via virtual thread)
   - WorkflowCompletionPublisher: `Consumer<WorkflowExecutionCompleted>`
   - WorkerRetrySupport: `Consumer<WorkerRetriesExhaustedEvent>`

5. **14 vestigial files deleted** — 7 FaultEventHandler + 7 EventBusAddresses classes. Per-module fault routing was illusory — all handlers delegated to the same shared WorkerFaultHandler. `faultAddress` parameter removed from entire pipeline including PendingCompletion record.

6. **Quarkus wiring** — WorkersCommonBeans @Produces core POJOs with EventBus consumers. CompletionExpiryScheduler handles the @Scheduled tick.

### Design artifacts

- Spec: `wsp-casehub-platform/specs/main/2026-09-25-workers-spring-boot-deployment-design.md`
- Decisions: `wsp-casehub-platform/specs/main/decisions.md` (D0-D4)
- Plan: `wsp-casehub-platform/plans/2026-09-25-workers-common-core-extraction.md`

### Key decisions (D0-D4)

- **D0:** Complete Vert.x removal — emergent from D1+D2+D3
- **D1:** void + virtual threads for WorkerRuntime lifecycle
- **D2:** Consumer<T> for all EventBus patterns
- **D3:** JDK HttpClient for WebClient replacement (follow-up)
- **D4:** workers-common-core first, per-module cores as follow-up

## Slot State

Seven repos complete. Workers Phase 1 done, Phase 2 (per-module cores + Spring auto-config) deferred.

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
| **workers** | **Phase 1 done** | `issue-24-spring-boot-deployment` |

## What's Next: workers#24 Phase 2 — Deferred Items

7 items in the .plan deferred list. Recommended order:

| # | Item | Scale | Complexity | Blocker |
|---|------|-------|------------|---------|
| 1 | Update tests for faultAddress removal | S | Low | None — do first, restores test compilation |
| 2 | Update docs for deleted classes | XS | Low | None |
| 3 | Fix K8s Optional<CaseInstance> error | XS | Low | Pre-existing, not from this branch |
| 4 | Per-module -core extraction (6 modules) | M | Low | Mechanical after tests pass |
| 5 | MCP -core extraction | M | High | Session mgmt + SSE parsing needs design |
| 6 | WebClient → JDK HttpClient (4 modules) | M | Med | Can parallel with #4/#5 |
| 7 | Consolidated workers-spring auto-config | M | Med | Depends on #4 + #5 completing |

Items 1-3 are quick wins to clean up loose ends. Items 4-7 are the remaining Spring deployment work.

### Known issues from this session

- workers-k8s has pre-existing `Optional<CaseInstance>` type mismatch (K8sJobInformerManager.java:191, K8sWorkerExecutionManager.java:188) — not caused by this branch
- Per-module test files reference deleted EventBusAddresses constants — test scope compilation broken, main sources compile clean
- MCP module retains temporary Mutiny bridge for McpSessionManager.shutdown() — full cleanup in MCP -core extraction
