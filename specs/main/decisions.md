# Decisions — workers#24 Spring Boot Deployment

## D1: WorkerRuntime Lifecycle — void + virtual threads

**Choice:** `void initialize()` / `void shutdown()` with orchestrator-owned parallelism via virtual threads
**Alternatives:**
- Uni<Void> (current) — Mutiny dependency for 1/7 genuinely async implementations; orchestrator blocks sequentially anyway
- CompletableFuture<Void> — preserves async in type signature but adds ceremony for 5/7 sync implementations
**Rationale:** The orchestrator owns inter-runtime parallelism, not each implementation. Current code has a production bug: sequential `.await().indefinitely()` with no timeout means a hung MCP server blocks ALL worker initialization forever. Virtual threads give parallel init with per-runtime timeouts and fault isolation. MCP handles internal parallelism (multi-server init) with virtual threads inside its own `initialize()`.
**Trade-offs:** Loses Mutiny reactive composition — but the orchestrator never composed reactively (it blocked sequentially). MCP's internal parallelism via `Uni.join().all()` becomes virtual thread pool — equivalent parallelism, simpler error handling.
**Sources:** WorkerLifecycleOrchestrator.java:45-48 (sequential await), WorkerRuntime.java (interface), McpWorkerRuntime.java (only genuinely async impl), HttpWorkerRuntime.java/ScriptWorkerRuntime.java/CamelWorkerRuntime.java/GitHubActionsWorkerRuntime.java/ScenarioWorkerRuntime.java (all sync Uni wrapping)
**Exploration:** deep-analysis
**Status:** captured

## D2: EventBus Replacement — Consumer<T> functional interfaces

**Choice:** `Consumer<T>` constructor parameters replacing all 3 EventBus patterns
**Alternatives:**
- Spring ApplicationEvent typed events — ties core to event dispatch model
- Direct call with Executor — less flexible, framework can't substitute its own event system
**Rationale:** Established casehub convention (platform-core, engine-core all use Consumer<T> for CDI Event<T> replacement). Per-module fault routing is vestigial — all 7 FaultEventHandlers are identical one-liners delegating to the same WorkerFaultHandler. Consumer<T> preserves fire-and-forget semantics while keeping core framework-neutral. The 7 *FaultEventHandler classes are deleted, not extracted.
**Trade-offs:** Requires framework layer to wrap Consumer in async submission (virtual thread) to preserve fire-and-forget semantics for fault handling (WorkerFaultHandler does Thread.sleep for retry backoff). Direct call would block the execution manager during retry delay.
**Sources:** WorkerFaultPublisher.java (EventBus.publish), WorkerFaultHandler.java (shared handler with Thread.sleep retry), HttpWorkerFaultEventHandler.java / McpWorkerFaultEventHandler.java (identical delegates), WorkflowCompletionPublisher.java (completion pattern), WorkerRetrySupport.java:155 (retries-exhausted pattern)
**Exploration:** deep-analysis
**Status:** captured

## D3: HTTP Client — JDK HttpClient

**Choice:** `java.net.http.HttpClient` for the 4 modules currently using Vert.x WebClient
**Alternatives:**
- Spring RestClient — ties core to Spring
- Abstract WorkerHttpClient SPI — over-engineered for straightforward request/response
**Rationale:** Zero dependency, virtual-thread friendly, sufficient for all 4 use cases (HTTP dispatch, GitHub API calls, MCP JSON-RPC, scenario callbacks). Same choice as platform's streams-poll module. No reactive streaming, SSE, or WebSocket in any of these modules.
**Trade-offs:** Slightly more verbose API than RestClient for JSON serialization — requires explicit ObjectMapper usage. Not a real cost given these modules already use ObjectMapper directly.
**Sources:** McpWorkerRuntime.java:121-131 (WebClient POST for tools/list), HttpWorkerExecutionManager (WebClient for HTTP dispatch), platform streams-poll module (precedent for JDK HttpClient)
**Exploration:** quick
**Status:** captured

## D4: Module Structure — workers-common-core first

**Choice:** Extract `workers-common-core` with shared infrastructure first. Per-module cores and consolidated `workers-spring` as follow-up.
**Alternatives:**
- Monolithic workers-core (all types in one module) — larger surface area, harder to review
- workers-common-core only, no per-module (this session only) — lower scope but defers the full architecture
**Rationale:** workers-common is the foundation — all 7 modules depend on it. Getting the shared infrastructure right (fault pipeline, completion, retry, lifecycle orchestrator) establishes patterns the per-module extraction follows mechanically. Consolidated workers-spring mirrors platform's agent-spring pattern.
**Trade-offs:** Defers per-module extraction — but each module follows the same pattern (ExecutionManager → POJO, Runtime → void, delete FaultEventHandler), making follow-up mechanical.
**Depends on:** D1 (lifecycle pattern), D2 (EventBus replacement pattern), D3 (HTTP client choice)
**Sources:** platform agent-spring module (consolidated Spring auto-config precedent), HANDOFF.md (audit: 40 beans across 8 modules)
**Exploration:** quick
**Status:** captured
