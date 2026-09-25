# workers#24 — Spring Boot Deployment Design

## Context

The casehub-workers repo contains 8 modules: `workers-common` (shared
infrastructure) plus 7 worker-type modules (http, camel, github-actions,
mcp, script, k8s, scenario). The Spring Boot deployment campaign has
completed 7 other repos; workers is the last.

Workers differs from the other repos because it uses Vert.x EventBus as
an architectural pattern — fault routing, completion notifications, and
retry dispatch all use `eventBus.publish()` and `@ConsumeEvent`. This
isn't just DI wiring; it's event-driven architecture.

A CDI audit (prior session) counted 40 beans across 8 modules. This spec
covers the shared infrastructure extraction (`workers-common-core`) and
establishes patterns for per-module extraction as follow-up work.

## Architecture

### Module Structure

```
workers-common-core/     ← NEW: framework-neutral POJOs (this spec)
workers-common/          ← SLIM: Quarkus wiring only (produces core POJOs)
workers-spring/          ← NEW: consolidated Spring auto-config (follow-up)
workers-http-core/       ← NEW: per-module core (follow-up, same pattern)
workers-http/            ← SLIM: Quarkus wiring only (follow-up)
... (repeat for each worker type)
```

`workers-common-core` has zero CDI, zero Vert.x, zero Mutiny. Pure Java
with constructor injection.

### What Moves to workers-common-core

| Class | Current deps | Core form |
|-------|-------------|-----------|
| WorkerFaultHandler | EventBus (unused Vertx inject), WorkerRetrySupport, WorkerExecutionManager, EventLogRepository | POJO — remove Vertx inject, constructor inject deps |
| WorkerRetrySupport | EventBus, EventLogRepository | POJO — replace `eventBus.publish(RETRIES_EXHAUSTED, ...)` with `Consumer<WorkerRetriesExhaustedEvent>` |
| WorkflowCompletionPublisher | EventBus | POJO — replace `eventBus.publish(EXECUTION_FINISHED, ...)` with `Consumer<WorkflowExecutionCompleted>` |
| WorkerFaultPublisher | EventBus | POJO — replace `eventBus.publish(faultAddress, event)` with `Consumer<WorkerFaultEvent>` |
| WorkerLifecycleOrchestrator | Quarkus StartupEvent, Instance<WorkerRuntime> | POJO — takes `List<WorkerRuntime>`, `Duration initTimeout`. Virtual thread parallel init. |
| AsyncWorkerCompletionRegistry | Quarkus @Scheduled, CDI Event | POJO — takes `Consumer<CompletionExpiredEvent>`. Public `expireStale()` method; framework calls it on a schedule. |
| WorkerStatusPublisher | CDI | POJO — already a delegate to WorkerStatusListener SPI |
| WorkerCapabilityResolver | none | Interface — already pure Java |
| WorkerProvisionerSupport | none | Static utility — already pure Java |
| WorkerCorrelationContext | none | Record — already pure Java |
| PendingCompletion | none | Record — already pure Java |
| WorkerFaultEvent | none | Record — already pure Java |
| WorkerCompletionPayload | none | Record — already pure Java |
| CompletionExpiredEvent | none | Record — already pure Java |
| FaultCallbackEvent | none | Record — already pure Java |
| WorkerRuntimeStatus | none | Enum — already pure Java |
| PermanentFaultException | none | Exception — already pure Java |
| RetryAfterException | none | Exception — already pure Java |
| WorkerProvisioningException | none | Exception — already pure Java |
| CasehubWorkerHeaders | none | Constants — already pure Java |

### What Stays in workers-common (Quarkus)

| Class | Reason |
|-------|--------|
| WorkerCallbackResource | JAX-RS @Path — framework-specific REST endpoint |
| WorkerFaultCallbackObserver | @ObservesAsync FaultCallbackEvent — CDI event observer |
| WorkerCompletionExpiryObserver | @ObservesAsync CompletionExpiredEvent — CDI event observer |
| Quarkus @Produces bean class | Wires core POJOs with CDI Event consumers and EventBus bridges |

### What Gets Deleted (Not Extracted)

| Class | Reason |
|-------|--------|
| 7 × *FaultEventHandler | Vestigial — all identical one-liners delegating to WorkerFaultHandler. Per-module EventBus addresses serve no behavioral purpose. |
| 7 × *EventBusAddresses | String constants for deleted fault handlers. Module-internal constants (WORKER_TYPE, etc.) stay. |

## EventBus Replacement

Three EventBus patterns exist. All use `eventBus.publish()` (fire-and-forget).

### Pattern A: Fault Routing (eliminated)

**Current:** `WorkerFaultPublisher.fault(faultAddress, event)` → EventBus →
per-module `@ConsumeEvent(address)` → `WorkerFaultHandler.handleFault(event)`

**After:** `WorkerFaultPublisher` takes `Consumer<WorkerFaultEvent>`. Framework
layer wraps in async submission (virtual thread) to preserve fire-and-forget
semantics — `handleFault()` does `Thread.sleep(delayMs)` for retry backoff
and must not block the calling execution manager.

Quarkus wiring:
```java
@Produces
WorkerFaultPublisher faultPublisher(WorkerFaultHandler handler) {
    return new WorkerFaultPublisher(event ->
        Thread.startVirtualThread(() -> handler.handleFault(event)));
}
```

Spring wiring:
```java
@Bean
WorkerFaultPublisher faultPublisher(WorkerFaultHandler handler) {
    return new WorkerFaultPublisher(event ->
        Thread.startVirtualThread(() -> handler.handleFault(event)));
}
```

### Pattern B: Completion (cross-repo, Consumer)

**Current:** `WorkflowCompletionPublisher.complete()` →
`eventBus.publish(WORKER_EXECUTION_FINISHED, WorkflowExecutionCompleted)`

**After:** Constructor takes `Consumer<WorkflowExecutionCompleted>`.
Framework layer bridges to engine's event consumer.

### Pattern C: Retries Exhausted (cross-repo, Consumer)

**Current:** `WorkerRetrySupport.publishRetriesExhausted()` →
`eventBus.publish(WORKER_RETRIES_EXHAUSTED, WorkerRetriesExhaustedEvent)`

**After:** Constructor takes `Consumer<WorkerRetriesExhaustedEvent>`.
Framework layer bridges to engine's event consumer.

### Cross-Boundary Wiring Note

Patterns B and C are cross-repo: workers publishes, engine consumes.
`EventBus.publish()` broadcasts to all listeners on an address. With
`Consumer<T>`, the wiring is explicit — the framework layer provides
the implementation. If any EventBus address has multiple consumers in
engine, the framework layer composes them into a single Consumer (e.g.,
`event -> { listener1.accept(event); listener2.accept(event); }`).
Engine's consumer implementations are external to this spec.

## WorkerRuntime Lifecycle

### Interface Change

```java
// Before (workers-common, Mutiny dependency)
public interface WorkerRuntime {
    Uni<Void> initialize();
    Uni<Void> shutdown();
    // ...
}

// After (workers-common-core, zero deps)
public interface WorkerRuntime {
    void initialize();
    void shutdown();
    String workerType();
    WorkerRuntimeStatus status();
    Set<String> capabilities();
}
```

### Orchestrator — Parallel Init with Timeouts

```java
public class WorkerLifecycleOrchestrator {
    private final List<WorkerRuntime> runtimes;
    private final Duration initTimeout;

    public void initializeAll() {
        if (runtimes.isEmpty()) { return; }
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var futures = runtimes.stream()
                .map(rt -> Map.entry(rt, executor.submit(() -> {
                    rt.initialize(); return rt;
                })))
                .toList();
            for (var entry : futures) {
                var rt = entry.getKey();
                try {
                    entry.getValue().get(initTimeout.toMillis(), TimeUnit.MILLISECONDS);
                    if (rt.status() == WorkerRuntimeStatus.RUNNING) {
                        LOG.infof("Worker '%s' initialized — capabilities: %s",
                            rt.workerType(), rt.capabilities());
                    } else {
                        LOG.warnf("Worker '%s' did not reach RUNNING — status: %s",
                            rt.workerType(), rt.status());
                    }
                } catch (TimeoutException e) {
                    LOG.warnf("Worker '%s' initialization timed out after %s",
                        rt.workerType(), initTimeout);
                } catch (ExecutionException e) {
                    LOG.warnf("Worker '%s' failed to initialize: %s",
                        rt.workerType(), e.getCause().getMessage());
                }
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    public void shutdownAll() {
        for (var rt : runtimes) {
            if (rt.status() == WorkerRuntimeStatus.PENDING) { continue; }
            try { rt.shutdown(); }
            catch (Exception e) {
                LOG.warnf("Worker '%s' shutdown failed: %s",
                    rt.workerType(), e.getMessage());
            }
        }
    }
}
```

### MCP Runtime — Internal Parallelism

McpWorkerRuntime's `initialize()` becomes blocking void but uses virtual
threads internally for parallel server initialization:

```java
@Override
public void initialize() {
    if (status == WorkerRuntimeStatus.RUNNING) { return; }
    if (serverResolver.serverNames().isEmpty()) {
        serverResolver.initializeFromConfig();
    }
    var serverNames = serverResolver.serverNames();
    if (serverNames.isEmpty()) {
        status = WorkerRuntimeStatus.FAULTED;
        return;
    }
    try (var pool = Executors.newVirtualThreadPerTaskExecutor()) {
        var futures = serverNames.stream()
            .map(name -> pool.submit(() -> initializeServer(name)))
            .toList();
        boolean anySuccess = false;
        for (var future : futures) {
            try {
                var result = future.get(30, TimeUnit.SECONDS);
                if (result.success()) {
                    anySuccess = true;
                    // register discovered tools...
                }
            } catch (Exception e) {
                LOG.warnf("MCP server init failed: %s", e.getMessage());
            }
        }
        status = anySuccess ? WorkerRuntimeStatus.RUNNING : WorkerRuntimeStatus.FAULTED;
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        status = WorkerRuntimeStatus.FAULTED;
    }
}
```

Vert.x WebClient replaced with JDK HttpClient for `tools/list` discovery
and MCP session initialization.

## HTTP Client Migration (4 modules)

Workers-http, workers-github-actions, workers-mcp, and workers-scenario
replace Vert.x `WebClient` with `java.net.http.HttpClient`.

JDK HttpClient is:
- Zero-dependency (already in JDK)
- Virtual-thread friendly (`send()` blocks on virtual thread without waste)
- Sufficient for all use cases (POST JSON, GET with headers, timeout support)
- MCP parses SSE response bodies in buffered mode (receive full body, then
  split on `\n\n`) — JDK HttpClient handles this identically. If MCP ever
  adopts true streaming SSE, `BodySubscribers.ofLines()` provides a path.

Per-request timeouts are mandatory — `HttpRequest.Builder.timeout()` must
be set on every call. This prevents reproducing the no-timeout production
bug identified in D1.

Each core module constructs its own `HttpClient` instance (or receives
one via constructor for testability).

## WorkerFaultHandler — Vertx Removal

`WorkerFaultHandler` currently injects `io.vertx.core.Vertx` but never
uses it — the retry delay uses `Thread.sleep(delayMs)`. The Vertx field
is deleted. `Thread.sleep()` is fine on virtual threads.

## Dependency Changes

### workers-common-core (new)

**Dependencies:** engine-common (for WorkerExecutionManager SPI,
EventLogRepository, WorkflowExecutionCompleted, WorkerRetriesExhaustedEvent),
worker-api (for Worker, Capability), platform-api (for RetryPolicy,
ExecutionPolicy). Zero framework deps.

### workers-common (slimmed)

**Removed deps:** Mutiny (`io.smallrye.mutiny`), Vert.x EventBus
(`io.vertx.mutiny.core.eventbus`), Vert.x core (`io.vertx.core`).

**Added deps:** workers-common-core.

**Retained deps:** Quarkus CDI, JAX-RS (for WorkerCallbackResource).

## Testing Strategy

### workers-common-core tests

Pure JUnit 5. No Quarkus test harness needed.

- WorkerFaultHandler: mock EventLogRepository, mock WorkerExecutionManager,
  verify retry/exhaust logic with Consumer captures
- WorkerRetrySupport: static methods already testable; instance methods
  get mock EventLogRepository and Consumer capture
- WorkerLifecycleOrchestrator: mock WorkerRuntime list, verify parallel
  init, verify timeout handling (mock runtime that sleeps past timeout),
  verify fault isolation (one throws, others succeed)
- AsyncWorkerCompletionRegistry: verify expiry callback fires, verify
  concurrent registration/completion

### workers-common Quarkus tests

Existing tests continue — they verify CDI wiring produces working core
POJOs. May need adjustment for constructor changes.

## Scope — This Session vs Follow-Up

### This session: workers-common-core

- Extract workers-common-core module
- Slim workers-common to Quarkus wiring
- Delete 7 FaultEventHandler classes + EventBusAddresses constants
- Update WorkerRuntime interface (Uni<Void> → void)
- Update WorkerLifecycleOrchestrator (parallel + timeout)
- Tests for core module

### Follow-up: per-module cores + workers-spring

- Extract workers-http-core, workers-mcp-core, etc. (mechanical)
- Replace Vert.x WebClient with JDK HttpClient in 4 modules
- Create consolidated workers-spring auto-config
- Spring integration test

## References

- WorkerLifecycleOrchestrator.java:45-48 — sequential await bug
- WorkerRuntime.java — interface with Mutiny Uni return types
- McpWorkerRuntime.java — only genuinely async implementation
- HttpWorkerFaultEventHandler.java — vestigial one-liner pattern
- WorkerFaultPublisher.java — EventBus publish pattern
- WorkerFaultHandler.java — shared handler with Thread.sleep retry
- WorkerRetrySupport.java:155 — retries-exhausted EventBus pattern
- WorkflowCompletionPublisher.java — completion EventBus pattern
- platform agent-spring module — consolidated Spring auto-config precedent
- platform streams-poll module — JDK HttpClient precedent
- HANDOFF.md — CDI audit data (40 beans, 8 modules)
