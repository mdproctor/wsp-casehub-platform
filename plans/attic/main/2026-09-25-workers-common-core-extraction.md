# workers-common-core Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/workers#24 — Spring Boot deployment
**Issue group:** casehubio/casehub-worker#16, casehubio/blocks#297, casehubio/workers#24

**Goal:** Extract framework-neutral POJOs from workers-common into a new
workers-common-core module, replacing Vert.x EventBus with Consumer<T>
and Mutiny Uni with void + virtual threads.

**Architecture:** Create workers-common-core (zero CDI, zero Vert.x)
containing all shared worker infrastructure as constructor-injected POJOs.
workers-common becomes a thin Quarkus wiring layer that produces core
POJOs with framework-specific consumers. Per-module FaultEventHandlers
are deleted — fault routing collapses to a single Consumer<WorkerFaultEvent>.

**Tech Stack:** Java 21+, Maven, JUnit 5, Mockito, AssertJ

## Global Constraints

- workers-common-core has zero CDI, zero Vert.x, zero Mutiny dependencies
- All EventBus patterns replaced with `Consumer<T>` constructor params
- WorkerRuntime interface returns `void`, not `Uni<Void>`
- Per-request timeouts mandatory on all HTTP client usage
- Virtual threads for parallel initialization (JDK 21 structured concurrency)
- Project repo: `/Users/mdproctor/claude/casehub/slots/198/workers`

---

## Batch 1: Module scaffold + pure type extraction

### Task 1: Create workers-common-core module and move pure types

**Files:**
- Create: `workers-common-core/pom.xml`
- Create: `workers-common-core/src/main/java/io/casehub/workers/common/` (directory)
- Modify: `pom.xml` (parent — add module)
- Modify: `workers-common/pom.xml` (add dependency on workers-common-core)
- Move: 14 pure Java types from `workers-common` to `workers-common-core`
- Test: `workers-common-core/src/test/java/io/casehub/workers/common/WorkerRetrySupportStaticTest.java`

**Interfaces:**
- Produces: All pure types in `io.casehub.workers.common` package (records,
  enums, exceptions, constants, interfaces) — same package, new module

- [ ] **Step 1: Add workers-common-core to parent pom.xml**

Add the module before workers-common in the `<modules>` list:

```xml
<module>workers-common-core</module>
<module>workers-common</module>
```

- [ ] **Step 2: Create workers-common-core/pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <parent>
        <groupId>io.casehub</groupId>
        <artifactId>casehub-workers-parent</artifactId>
        <version>0.2-SNAPSHOT</version>
    </parent>

    <artifactId>casehub-workers-common-core</artifactId>

    <name>CaseHub Workers :: Common Core</name>
    <description>Framework-neutral worker infrastructure POJOs — fault pipeline,
        completion registry, lifecycle orchestrator. Zero CDI, zero Vert.x.</description>

    <dependencies>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-engine-api</artifactId>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-engine-common</artifactId>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-worker-api</artifactId>
        </dependency>
        <dependency>
            <groupId>io.casehub</groupId>
            <artifactId>casehub-platform-api</artifactId>
        </dependency>
        <dependency>
            <groupId>com.fasterxml.jackson.core</groupId>
            <artifactId>jackson-databind</artifactId>
        </dependency>

        <dependency>
            <groupId>org.junit.jupiter</groupId>
            <artifactId>junit-jupiter</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.assertj</groupId>
            <artifactId>assertj-core</artifactId>
            <scope>test</scope>
        </dependency>
        <dependency>
            <groupId>org.mockito</groupId>
            <artifactId>mockito-core</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
</project>
```

- [ ] **Step 3: Create source directories**

```bash
mkdir -p workers-common-core/src/main/java/io/casehub/workers/common
mkdir -p workers-common-core/src/test/java/io/casehub/workers/common
```

- [ ] **Step 4: Move pure Java types to workers-common-core**

Use `ide_move_file` for each file. These files have zero framework
dependencies — they are records, enums, exceptions, constants, and
interfaces that are already pure Java:

| File | Type |
|------|------|
| `WorkerRuntimeStatus.java` | enum |
| `WorkerCorrelationContext.java` | record/class |
| `PendingCompletion.java` | record |
| `WorkerFaultEvent.java` | record |
| `WorkerCompletionPayload.java` | record |
| `CompletionExpiredEvent.java` | record |
| `FaultCallbackEvent.java` | record |
| `PermanentFaultException.java` | exception |
| `RetryAfterException.java` | exception |
| `WorkerProvisioningException.java` | exception |
| `CasehubWorkerHeaders.java` | constants |
| `WorkerCapabilityResolver.java` | interface |
| `WorkerProvisionerSupport.java` | static utility |
| `WorkerStatusPublisher.java` | delegate class |

Source: `workers-common/src/main/java/io/casehub/workers/common/<File>`
Dest: `workers-common-core/src/main/java/io/casehub/workers/common/<File>`

All files stay in the same package (`io.casehub.workers.common`) — no
import changes needed in consuming modules.

- [ ] **Step 5: Add workers-common-core dependency to workers-common**

In `workers-common/pom.xml`, add before the existing dependencies:

```xml
<dependency>
    <groupId>io.casehub</groupId>
    <artifactId>casehub-workers-common-core</artifactId>
</dependency>
```

- [ ] **Step 6: Write test for static utility methods**

```java
package io.casehub.workers.common;

import io.casehub.platform.api.governance.BackoffStrategy;
import io.casehub.platform.api.governance.RetryPolicy;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class WorkerRetrySupportStaticTest {

    @Test
    void fixedBackoff_returnsBaseDelay() {
        var policy = new RetryPolicy(3, 1000L, BackoffStrategy.FIXED);
        assertThat(WorkerRetrySupport.computeBackoffDelayMs(policy, 1)).isEqualTo(1000L);
        assertThat(WorkerRetrySupport.computeBackoffDelayMs(policy, 3)).isEqualTo(1000L);
    }

    @Test
    void exponentialBackoff_doublesPerAttempt() {
        var policy = new RetryPolicy(5, 500L, BackoffStrategy.EXPONENTIAL);
        assertThat(WorkerRetrySupport.computeBackoffDelayMs(policy, 1)).isEqualTo(500L);
        assertThat(WorkerRetrySupport.computeBackoffDelayMs(policy, 2)).isEqualTo(1000L);
        assertThat(WorkerRetrySupport.computeBackoffDelayMs(policy, 3)).isEqualTo(2000L);
    }

    @Test
    void exponentialBackoff_cappedAt30Seconds() {
        var policy = new RetryPolicy(10, 1000L, BackoffStrategy.EXPONENTIAL);
        assertThat(WorkerRetrySupport.computeBackoffDelayMs(policy, 20)).isEqualTo(30_000L);
    }

    @Test
    void parseRetryAfter_integerSeconds() {
        var ex = WorkerRetrySupport.parseRetryAfter("5", 429, "Too Many Requests");
        assertThat(ex).isInstanceOf(RetryAfterException.class);
        assertThat(((RetryAfterException) ex).retryAfterMs()).isEqualTo(5000L);
    }

    @Test
    void parseRetryAfter_nullReturnsRuntimeException() {
        var ex = WorkerRetrySupport.parseRetryAfter(null, 500, "Internal Server Error");
        assertThat(ex).isNotInstanceOf(RetryAfterException.class);
    }
}
```

Note: `WorkerRetrySupport` has not been moved yet — that happens in
Batch 3. This test verifies that static methods (which have zero
framework dependencies) compile and run in the core module. The test
file is created now but won't compile until Batch 3 moves
`WorkerRetrySupport`. **Create the file but skip running it until
Batch 3.**

- [ ] **Step 7: Verify compilation**

Run: `mvn --batch-mode compile -pl workers-common-core,workers-common -am`
Expected: BUILD SUCCESS — pure types compile in core, workers-common
resolves them transitively.

- [ ] **Step 8: Commit**

```bash
git add workers-common-core/ pom.xml workers-common/pom.xml
git commit -m "feat(#24): create workers-common-core module with pure types

Extract 14 framework-neutral types (records, enums, exceptions,
constants, interfaces) from workers-common to workers-common-core.
Same package — no import changes in consumers.

Refs casehubio/workers#24

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 2: WorkerRuntime void + lifecycle orchestrator

### Task 2: Change WorkerRuntime interface to void, update all implementations

**Files:**
- Modify: `workers-common-core/src/main/java/io/casehub/workers/common/WorkerRuntime.java` (already in core from Task 1)
- Modify: `workers-http/src/main/java/io/casehub/workers/http/HttpWorkerRuntime.java`
- Modify: `workers-camel/src/main/java/io/casehub/workers/camel/CamelWorkerRuntime.java`
- Modify: `workers-github-actions/src/main/java/io/casehub/workers/githubactions/GitHubActionsWorkerRuntime.java`
- Modify: `workers-mcp/src/main/java/io/casehub/workers/mcp/McpWorkerRuntime.java`
- Modify: `workers-script/src/main/java/io/casehub/workers/script/ScriptWorkerRuntime.java`
- Modify: `workers-k8s/src/main/java/io/casehub/workers/k8s/K8sWorkerRuntime.java`
- Modify: `workers-scenario/src/main/java/io/casehub/workers/scenario/ScenarioWorkerRuntime.java`
- Test: `workers-common-core/src/test/java/io/casehub/workers/common/WorkerLifecycleOrchestratorTest.java`

**Interfaces:**
- Consumes: `WorkerRuntime` interface (from Task 1)
- Produces: `WorkerRuntime` with `void initialize()` / `void shutdown()`

- [ ] **Step 1: Change WorkerRuntime interface**

Replace the Mutiny Uni signatures with void. Remove the Mutiny import.

```java
package io.casehub.workers.common;

import java.util.Set;

public interface WorkerRuntime {
    String workerType();
    WorkerRuntimeStatus status();
    void initialize();
    void shutdown();
    Set<String> capabilities();
}
```

- [ ] **Step 2: Update HttpWorkerRuntime**

Remove Uni wrapping — the body is already synchronous:

```java
@Override
public void initialize() {
    if (status == WorkerRuntimeStatus.RUNNING) { return; }
    try {
        resolver.initialize();
        status = WorkerRuntimeStatus.RUNNING;
    } catch (Exception e) {
        status = WorkerRuntimeStatus.FAULTED;
        throw e;
    }
}

@Override
public void shutdown() {
    status = WorkerRuntimeStatus.STOPPED;
}
```

Remove `import io.smallrye.mutiny.Uni;`.

- [ ] **Step 3: Update CamelWorkerRuntime**

Identical pattern to HTTP — unwrap Uni, remove import:

```java
@Override
public void initialize() {
    if (status == WorkerRuntimeStatus.RUNNING) { return; }
    try {
        resolver.initialize();
        status = WorkerRuntimeStatus.RUNNING;
    } catch (Exception e) {
        status = WorkerRuntimeStatus.FAULTED;
        throw e;
    }
}

@Override
public void shutdown() {
    status = WorkerRuntimeStatus.STOPPED;
}
```

- [ ] **Step 4: Update GitHubActionsWorkerRuntime**

```java
@Override
public void initialize() {
    if (status == WorkerRuntimeStatus.RUNNING) { return; }
    if (tokenResolver.hasToken()) {
        status = WorkerRuntimeStatus.RUNNING;
    } else {
        LOG.warn("GitHub Actions worker has no configured token — status FAULTED");
        status = WorkerRuntimeStatus.FAULTED;
    }
}

@Override
public void shutdown() {
    status = WorkerRuntimeStatus.STOPPED;
}
```

- [ ] **Step 5: Update ScriptWorkerRuntime**

```java
@Override
public void initialize() {
    if (status == WorkerRuntimeStatus.RUNNING) { return; }
    try {
        if (resolver.capabilities().isEmpty()) {
            resolver.initialize();
        }
        if (resolver.capabilities().isEmpty()) {
            LOG.warn("No scripts configured — status FAULTED");
            status = WorkerRuntimeStatus.FAULTED;
        } else {
            status = WorkerRuntimeStatus.RUNNING;
        }
    } catch (Exception e) {
        status = WorkerRuntimeStatus.FAULTED;
        throw e;
    }
}

@Override
public void shutdown() {
    status = WorkerRuntimeStatus.STOPPED;
}
```

- [ ] **Step 6: Update ScenarioWorkerRuntime**

```java
@Override
public void initialize() {
    if (status == WorkerRuntimeStatus.RUNNING) { return; }
    try {
        if (resolver.endpointNames().isEmpty()) {
            resolver.initializeFromConfig();
        }
        if (resolver.endpointNames().isEmpty()) {
            LOG.warn("No scenario endpoints configured — status FAULTED");
            status = WorkerRuntimeStatus.FAULTED;
        } else {
            status = WorkerRuntimeStatus.RUNNING;
        }
    } catch (Exception e) {
        status = WorkerRuntimeStatus.FAULTED;
        throw e;
    }
}

@Override
public void shutdown() {
    status = WorkerRuntimeStatus.STOPPED;
}
```

- [ ] **Step 7: Update K8sWorkerRuntime**

Remove `runSubscriptionOn(Infrastructure.getDefaultWorkerPool())` — the
orchestrator handles threading. Remove Mutiny/Infrastructure imports:

```java
@Override
public void initialize() {
    if (status == WorkerRuntimeStatus.RUNNING) { return; }
    if (resolver.capabilities().isEmpty()) {
        status = WorkerRuntimeStatus.FAULTED;
        LOG.warn("No K8s job definitions configured — runtime FAULTED");
        return;
    }
    try {
        kubernetesClient.getApiVersion();
    } catch (Exception e) {
        status = WorkerRuntimeStatus.FAULTED;
        LOG.warnf("K8s cluster unreachable: %s — runtime FAULTED", e.getMessage());
        return;
    }
    Set<String> namespaces = resolver.namespaces();
    informerManager.start(namespaces);
    if (!informerManager.hasActiveInformers()) {
        status = WorkerRuntimeStatus.FAULTED;
        LOG.warn("All namespace informers failed — runtime FAULTED");
        return;
    }
    status = WorkerRuntimeStatus.RUNNING;
}

@Override
public void shutdown() {
    informerManager.stop();
    status = WorkerRuntimeStatus.STOPPED;
}
```

- [ ] **Step 8: Update McpWorkerRuntime**

This is the most complex — replace `Uni.join().all()` with virtual thread
parallel init. Remove Vert.x WebClient for now (Task 2 only changes
lifecycle signatures; WebClient replacement is follow-up scope). Keep the
initialize() body but replace Uni composition with virtual threads:

```java
@Override
public void initialize() {
    if (status == WorkerRuntimeStatus.RUNNING) { return; }
    if (serverResolver.serverNames().isEmpty()) {
        serverResolver.initializeFromConfig();
    }
    List<String> serverNames = serverResolver.serverNames();
    if (serverNames.isEmpty()) {
        LOG.warn("No MCP servers configured — status FAULTED");
        status = WorkerRuntimeStatus.FAULTED;
        return;
    }
    try (var pool = Executors.newVirtualThreadPerTaskExecutor()) {
        var futures = serverNames.stream()
            .map(name -> pool.submit(() -> initializeServer(name)))
            .toList();
        processResults(futures);
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        status = WorkerRuntimeStatus.FAULTED;
    }
}

@Override
public void shutdown() {
    try {
        sessionManager.shutdownBlocking();
        status = WorkerRuntimeStatus.STOPPED;
    } catch (Exception err) {
        LOG.warnf("Error during MCP shutdown: %s", err.getMessage());
        status = WorkerRuntimeStatus.STOPPED;
    }
}
```

Note: `initializeServer()` and `processResults()` also need updating
to remove Uni return types. `sessionManager.shutdown()` currently returns
`Uni<Void>` — it needs a `shutdownBlocking()` equivalent or the session
manager interface needs updating. This is implementation detail — the
key change is removing Uni from the WorkerRuntime interface.

The MCP module's internal refactoring (WebClient → HttpClient, Uni
chains → blocking) is follow-up scope per D4. For this task, make MCP
compile with `void initialize()` by converting the Uni chain to blocking
calls using `.await().indefinitely()` as a temporary bridge, then remove
the Uni imports from the interface.

- [ ] **Step 9: Update WorkerLifecycleOrchestrator (still in workers-common)**

Change `initializeAll()` and `shutdownAll()` to call void methods
directly (no `.await().indefinitely()`):

```java
void initializeAll(List<WorkerRuntime> workerRuntimes) {
    if (workerRuntimes.isEmpty()) {
        LOG.info("No WorkerRuntime beans discovered");
        return;
    }
    for (WorkerRuntime runtime : workerRuntimes) {
        try {
            runtime.initialize();
            if (runtime.status() == WorkerRuntimeStatus.RUNNING) {
                LOG.infof("Worker '%s' initialized — capabilities: %s",
                    runtime.workerType(), runtime.capabilities());
            } else {
                LOG.warnf("Worker '%s' did not reach RUNNING — status: %s",
                    runtime.workerType(), runtime.status());
            }
        } catch (Exception e) {
            LOG.warnf("Worker '%s' failed to initialize: %s",
                runtime.workerType(), e.getMessage());
        }
    }
}
```

This is a temporary sequential version — Task 3 extracts to core with
parallel virtual thread init.

- [ ] **Step 10: Verify full compilation**

Run: `mvn --batch-mode compile`
Expected: BUILD SUCCESS — all 9 modules compile with void WorkerRuntime.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat(#24): change WorkerRuntime to void, remove Mutiny from interface

All 7 WorkerRuntime implementations updated from Uni<Void> to void.
Orchestrator calls void methods directly (sequential for now —
parallel virtual thread init in next task).

Refs casehubio/workers#24

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 3: Extract WorkerLifecycleOrchestrator to core with parallel init

**Files:**
- Create: `workers-common-core/src/main/java/io/casehub/workers/common/WorkerLifecycleOrchestrator.java`
- Modify: `workers-common/src/main/java/io/casehub/workers/common/WorkerLifecycleOrchestrator.java` → becomes thin Quarkus wrapper
- Test: `workers-common-core/src/test/java/io/casehub/workers/common/WorkerLifecycleOrchestratorTest.java`

**Interfaces:**
- Consumes: `WorkerRuntime` (void interface from Task 2)
- Produces: `WorkerLifecycleOrchestrator(List<WorkerRuntime>, Duration)`

- [ ] **Step 1: Write failing test for parallel init**

```java
package io.casehub.workers.common;

import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;

class WorkerLifecycleOrchestratorTest {

    @Test
    void initializeAll_parallelExecution() {
        var initOrder = new AtomicInteger(0);
        var rt1 = new StubRuntime("rt1", 200, initOrder);
        var rt2 = new StubRuntime("rt2", 200, initOrder);
        var rt3 = new StubRuntime("rt3", 200, initOrder);

        var orchestrator = new WorkerLifecycleOrchestrator(
            List.of(rt1, rt2, rt3), Duration.ofSeconds(5));

        long start = System.nanoTime();
        orchestrator.initializeAll();
        long elapsedMs = (System.nanoTime() - start) / 1_000_000;

        assertThat(rt1.status()).isEqualTo(WorkerRuntimeStatus.RUNNING);
        assertThat(rt2.status()).isEqualTo(WorkerRuntimeStatus.RUNNING);
        assertThat(rt3.status()).isEqualTo(WorkerRuntimeStatus.RUNNING);
        // Parallel: 3×200ms should complete well under 600ms
        assertThat(elapsedMs).isLessThan(500);
    }

    @Test
    void initializeAll_timeoutDoesNotBlockOthers() {
        var fast = new StubRuntime("fast", 0, new AtomicInteger());
        var slow = new StubRuntime("slow", 5000, new AtomicInteger());

        var orchestrator = new WorkerLifecycleOrchestrator(
            List.of(slow, fast), Duration.ofMillis(500));

        long start = System.nanoTime();
        orchestrator.initializeAll();
        long elapsedMs = (System.nanoTime() - start) / 1_000_000;

        assertThat(fast.status()).isEqualTo(WorkerRuntimeStatus.RUNNING);
        // Slow runtime timed out — doesn't reach RUNNING
        assertThat(elapsedMs).isLessThan(1000);
    }

    @Test
    void initializeAll_faultIsolation() {
        var good = new StubRuntime("good", 0, new AtomicInteger());
        var bad = new FailingRuntime("bad");

        var orchestrator = new WorkerLifecycleOrchestrator(
            List.of(bad, good), Duration.ofSeconds(5));

        orchestrator.initializeAll();

        assertThat(good.status()).isEqualTo(WorkerRuntimeStatus.RUNNING);
        assertThat(bad.status()).isEqualTo(WorkerRuntimeStatus.FAULTED);
    }

    @Test
    void shutdownAll_skips_pendingRuntimes() {
        var pending = new StubRuntime("pending", 0, new AtomicInteger());
        // Don't initialize — stays PENDING

        var orchestrator = new WorkerLifecycleOrchestrator(
            List.of(pending), Duration.ofSeconds(5));
        orchestrator.shutdownAll();

        assertThat(pending.status()).isEqualTo(WorkerRuntimeStatus.PENDING);
    }

    static class StubRuntime implements WorkerRuntime {
        private final String type;
        private final long initDelayMs;
        private final AtomicInteger order;
        private volatile WorkerRuntimeStatus status = WorkerRuntimeStatus.PENDING;

        StubRuntime(String type, long initDelayMs, AtomicInteger order) {
            this.type = type;
            this.initDelayMs = initDelayMs;
            this.order = order;
        }

        @Override public String workerType() { return type; }
        @Override public WorkerRuntimeStatus status() { return status; }
        @Override public Set<String> capabilities() { return Set.of(type); }

        @Override
        public void initialize() {
            try { Thread.sleep(initDelayMs); } catch (InterruptedException e) {
                Thread.currentThread().interrupt(); return;
            }
            order.incrementAndGet();
            status = WorkerRuntimeStatus.RUNNING;
        }

        @Override
        public void shutdown() { status = WorkerRuntimeStatus.STOPPED; }
    }

    static class FailingRuntime implements WorkerRuntime {
        private final String type;
        private volatile WorkerRuntimeStatus status = WorkerRuntimeStatus.PENDING;

        FailingRuntime(String type) { this.type = type; }

        @Override public String workerType() { return type; }
        @Override public WorkerRuntimeStatus status() { return status; }
        @Override public Set<String> capabilities() { return Set.of(); }

        @Override
        public void initialize() {
            status = WorkerRuntimeStatus.FAULTED;
            throw new RuntimeException("init failed");
        }

        @Override
        public void shutdown() { status = WorkerRuntimeStatus.STOPPED; }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl workers-common-core -Dtest=WorkerLifecycleOrchestratorTest`
Expected: FAIL — `WorkerLifecycleOrchestrator` class doesn't exist in core yet.

- [ ] **Step 3: Create core WorkerLifecycleOrchestrator**

```java
package io.casehub.workers.common;

import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.logging.Level;
import java.util.logging.Logger;

public class WorkerLifecycleOrchestrator {

    private static final Logger LOG = Logger.getLogger(
        WorkerLifecycleOrchestrator.class.getName());

    private final List<WorkerRuntime> runtimes;
    private final Duration initTimeout;

    public WorkerLifecycleOrchestrator(List<WorkerRuntime> runtimes,
                                       Duration initTimeout) {
        this.runtimes = List.copyOf(runtimes);
        this.initTimeout = initTimeout;
    }

    public void initializeAll() {
        if (runtimes.isEmpty()) {
            LOG.info("No WorkerRuntime beans discovered — no worker modules on classpath");
            return;
        }
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var futures = runtimes.stream()
                .map(rt -> Map.entry(rt, executor.submit(() -> {
                    rt.initialize();
                    return rt;
                })))
                .toList();
            for (var entry : futures) {
                var rt = entry.getKey();
                try {
                    entry.getValue().get(initTimeout.toMillis(), TimeUnit.MILLISECONDS);
                    if (rt.status() == WorkerRuntimeStatus.RUNNING) {
                        LOG.info(String.format("Worker '%s' initialized — capabilities: %s",
                            rt.workerType(), rt.capabilities()));
                    } else {
                        LOG.warning(String.format(
                            "Worker '%s' did not reach RUNNING after initialize() — status: %s",
                            rt.workerType(), rt.status()));
                    }
                } catch (TimeoutException e) {
                    LOG.warning(String.format(
                        "Worker '%s' initialization timed out after %s",
                        rt.workerType(), initTimeout));
                } catch (ExecutionException e) {
                    LOG.warning(String.format("Worker '%s' failed to initialize: %s",
                        rt.workerType(), e.getCause().getMessage()));
                }
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    public void shutdownAll() {
        for (var rt : runtimes) {
            if (rt.status() == WorkerRuntimeStatus.PENDING) { continue; }
            try {
                rt.shutdown();
            } catch (Exception e) {
                LOG.warning(String.format("Worker '%s' shutdown failed: %s",
                    rt.workerType(), e.getMessage()));
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mvn --batch-mode test -pl workers-common-core -Dtest=WorkerLifecycleOrchestratorTest`
Expected: PASS — all 4 tests green.

- [ ] **Step 5: Convert workers-common's orchestrator to thin Quarkus wrapper**

Replace the existing `WorkerLifecycleOrchestrator` in workers-common with
a Quarkus-specific bean that delegates to the core class:

```java
package io.casehub.workers.common;

import io.quarkus.runtime.StartupEvent;
import jakarta.annotation.PreDestroy;
import jakarta.annotation.Priority;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.event.Observes;
import jakarta.enterprise.inject.Any;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;
import java.time.Duration;

import static jakarta.interceptor.Interceptor.Priority.APPLICATION;

@ApplicationScoped
public class QuarkusWorkerLifecycleOrchestrator {

    @Inject @Any
    Instance<WorkerRuntime> runtimes;

    private WorkerLifecycleOrchestrator delegate;

    void onStartup(@Observes @Priority(APPLICATION + 10) StartupEvent ev) {
        if (runtimes == null || runtimes.isUnsatisfied()) { return; }
        delegate = new WorkerLifecycleOrchestrator(
            runtimes.stream().toList(), Duration.ofSeconds(30));
        delegate.initializeAll();
    }

    @PreDestroy
    void onShutdown() {
        if (delegate != null) {
            delegate.shutdownAll();
        }
    }
}
```

Delete the old `WorkerLifecycleOrchestrator.java` from workers-common
(use `ide_refactor_safe_delete` if no other references, or just replace
the file content).

- [ ] **Step 6: Verify full compilation**

Run: `mvn --batch-mode compile`
Expected: BUILD SUCCESS

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(#24): extract WorkerLifecycleOrchestrator with parallel virtual thread init

Core orchestrator runs all runtimes in parallel on virtual threads
with per-runtime timeouts. Fixes production bug where a hung MCP
server blocks all worker initialization.

Refs casehubio/workers#24

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 3: Event pipeline extraction with Consumer<T>

### Task 4: Extract fault/completion/retry publishers + WorkerFaultHandler to core

**Files:**
- Move+Modify: `WorkerFaultPublisher.java` → core, replace EventBus with Consumer<WorkerFaultEvent>
- Move+Modify: `WorkflowCompletionPublisher.java` → core, replace EventBus with Consumer<WorkflowExecutionCompleted>
- Move+Modify: `WorkerRetrySupport.java` → core, replace EventBus with Consumer<WorkerRetriesExhaustedEvent>
- Move+Modify: `WorkerFaultHandler.java` → core, remove Vertx inject
- Move+Modify: `AsyncWorkerCompletionRegistry.java` → core, replace @Scheduled and CDI Event with Consumer
- Test: `workers-common-core/src/test/java/io/casehub/workers/common/WorkerFaultHandlerTest.java`
- Test: `workers-common-core/src/test/java/io/casehub/workers/common/AsyncWorkerCompletionRegistryTest.java`

**Interfaces:**
- Consumes: Pure types from Task 1, `WorkerRuntime` from Task 2
- Produces:
  - `WorkerFaultPublisher(Consumer<WorkerFaultEvent>)`
  - `WorkflowCompletionPublisher(Consumer<WorkflowExecutionCompleted>)`
  - `WorkerRetrySupport(EventLogRepository, Consumer<WorkerRetriesExhaustedEvent>)`
  - `WorkerFaultHandler(WorkerRetrySupport, WorkerExecutionManager, EventLogRepository)`
  - `AsyncWorkerCompletionRegistry(Consumer<CompletionExpiredEvent>)`

- [ ] **Step 1: Write failing test for WorkerFaultHandler**

```java
package io.casehub.workers.common;

import io.casehub.engine.common.internal.history.EventLog;
import io.casehub.engine.common.spi.EventLogRepository;
import io.casehub.engine.common.spi.scheduler.WorkerExecutionManager;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

class WorkerFaultHandlerTest {

    EventLogRepository eventLogRepo = mock(EventLogRepository.class);
    WorkerExecutionManager executionManager = mock(WorkerExecutionManager.class);
    java.util.concurrent.atomic.AtomicReference<Object> exhaustedCapture =
        new java.util.concurrent.atomic.AtomicReference<>();
    WorkerRetrySupport retrySupport;
    WorkerFaultHandler handler;

    @BeforeEach
    void setUp() {
        retrySupport = new WorkerRetrySupport(eventLogRepo, exhaustedCapture::set);
        handler = new WorkerFaultHandler(retrySupport, executionManager, eventLogRepo);
    }

    @Test
    void permanentFault_publishesExhaustedImmediately() {
        var event = TestFixtures.faultEvent(new PermanentFaultException("bad input"));

        handler.handleFault(event);

        assertThat(exhaustedCapture.get()).isNotNull();
        verify(executionManager, never()).submit(any(), any(), any(), any(), any(), any());
    }
}
```

Note: `TestFixtures` helper will need creating with minimal stubs for
`CaseInstance`, `Worker`, etc. Use inline mocks or static factory.

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl workers-common-core -Dtest=WorkerFaultHandlerTest`
Expected: FAIL — classes not in core yet.

- [ ] **Step 3: Extract WorkerFaultPublisher to core**

New core version — replace EventBus with Consumer:

```java
package io.casehub.workers.common;

import io.casehub.worker.api.Capability;
import java.util.function.Consumer;

public class WorkerFaultPublisher {

    private final Consumer<WorkerFaultEvent> faultConsumer;

    public WorkerFaultPublisher(Consumer<WorkerFaultEvent> faultConsumer) {
        this.faultConsumer = faultConsumer;
    }

    public void fault(WorkerCorrelationContext ctx,
                      Capability capability, Long eventLogId, Throwable cause) {
        faultConsumer.accept(new WorkerFaultEvent(
            ctx.caseInstance(), ctx.worker(), capability,
            ctx.idempotency(), eventLogId.toString(), cause, ctx.bindingName()));
    }

    public void fault(PendingCompletion pending, Throwable cause) {
        faultConsumer.accept(new WorkerFaultEvent(
            pending.correlationContext().caseInstance(),
            pending.correlationContext().worker(),
            pending.capability(),
            pending.correlationContext().idempotency(),
            pending.eventLogId().toString(),
            cause,
            pending.correlationContext().bindingName()));
    }
}
```

Note: the `faultAddress` parameter is removed from `fault()` — it was
only needed for per-module EventBus routing, which is eliminated.
Callers that passed `faultAddress` will need updating — the execution
managers in per-module modules pass it. Update their calls to use the
new signature (remove the faultAddress arg). This affects all 7
execution managers — update them to call `faultPublisher.fault(ctx, capability, eventLogId, cause)`.

- [ ] **Step 4: Extract WorkflowCompletionPublisher to core**

```java
package io.casehub.workers.common;

import io.casehub.engine.common.internal.event.WorkflowExecutionCompleted;
import java.util.Map;
import java.util.function.Consumer;

public class WorkflowCompletionPublisher {

    private final Consumer<WorkflowExecutionCompleted> completionConsumer;

    public WorkflowCompletionPublisher(
            Consumer<WorkflowExecutionCompleted> completionConsumer) {
        this.completionConsumer = completionConsumer;
    }

    public void complete(WorkerCorrelationContext ctx, Map<String, Object> output) {
        completionConsumer.accept(
            WorkflowExecutionCompleted.approved(
                ctx.caseInstance(), ctx.worker(), ctx.idempotency(),
                output, ctx.bindingName()));
    }
}
```

- [ ] **Step 5: Extract WorkerRetrySupport to core**

Move to core, replace `EventBus` with `Consumer`:

```java
package io.casehub.workers.common;

import io.casehub.engine.common.internal.event.WorkerRetriesExhaustedEvent;
import io.casehub.engine.common.spi.EventLogRepository;
// ... (keep all existing static methods unchanged)
import java.util.function.Consumer;

public class WorkerRetrySupport {
    // ... (static methods unchanged — computeBackoffDelayMs, resolveRetryPolicy, parseRetryAfter)

    private final EventLogRepository eventLogRepository;
    private final Consumer<WorkerRetriesExhaustedEvent> retriesExhaustedConsumer;

    public WorkerRetrySupport(EventLogRepository eventLogRepository,
                              Consumer<WorkerRetriesExhaustedEvent> retriesExhaustedConsumer) {
        this.eventLogRepository = eventLogRepository;
        this.retriesExhaustedConsumer = retriesExhaustedConsumer;
    }

    // persistFailureLog — unchanged (uses eventLogRepository)
    // countFailedAttempts — unchanged (uses eventLogRepository)

    public void publishRetriesExhausted(java.util.UUID caseId, String workerId,
                                        String inputDataHash, String bindingName,
                                        String tenancyId) {
        retriesExhaustedConsumer.accept(
            new WorkerRetriesExhaustedEvent(caseId, tenancyId, workerId,
                inputDataHash, bindingName, null, null));
    }
}
```

- [ ] **Step 6: Extract WorkerFaultHandler to core**

Remove `@Inject Vertx` (unused field). Constructor injection:

```java
package io.casehub.workers.common;

import io.casehub.engine.common.spi.EventLogRepository;
import io.casehub.engine.common.spi.scheduler.WorkerExecutionManager;
// ... (keep existing imports minus Vertx and CDI)

public class WorkerFaultHandler {

    private final WorkerRetrySupport retrySupport;
    private final WorkerExecutionManager workerExecutionManager;
    private final EventLogRepository eventLogRepository;

    public WorkerFaultHandler(WorkerRetrySupport retrySupport,
                              WorkerExecutionManager workerExecutionManager,
                              EventLogRepository eventLogRepository) {
        this.retrySupport = retrySupport;
        this.workerExecutionManager = workerExecutionManager;
        this.eventLogRepository = eventLogRepository;
    }

    // handleFault() — unchanged logic
    // reloadAndResubmit() — unchanged logic (Thread.sleep is fine on virtual threads)
}
```

- [ ] **Step 7: Extract AsyncWorkerCompletionRegistry to core**

Replace `@Scheduled` with public `expireStale()` method. Replace
`Event<CompletionExpiredEvent>.fireAsync()` with `Consumer`:

```java
package io.casehub.workers.common;

import io.casehub.worker.api.Capability;
import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Consumer;

public class AsyncWorkerCompletionRegistry {

    private final Consumer<CompletionExpiredEvent> expiryConsumer;
    private final ConcurrentHashMap<String, PendingCompletion> pending =
        new ConcurrentHashMap<>();

    public AsyncWorkerCompletionRegistry(
            Consumer<CompletionExpiredEvent> expiryConsumer) {
        this.expiryConsumer = expiryConsumer;
    }

    public PendingCompletion register(String workerType,
                                      WorkerCorrelationContext ctx,
                                      Capability capability, Long eventLogId,
                                      Duration ttl, Map<String, String> provisionerMeta) {
        Instant now = Instant.now();
        PendingCompletion entry = new PendingCompletion(
            UUID.randomUUID().toString(), workerType, ctx,
            UUID.randomUUID().toString(), capability, eventLogId,
            now, now.plus(ttl), provisionerMeta);
        pending.put(entry.dispatchId(), entry);
        return entry;
    }

    public Optional<PendingCompletion> complete(String dispatchId) {
        return Optional.ofNullable(pending.remove(dispatchId));
    }

    public int countByWorkerName(String workerName) {
        return (int) pending.values().stream()
            .filter(p -> p.correlationContext().worker().name().equals(workerName))
            .count();
    }

    public void expireStale() {
        pending.forEach((key, value) ->
            pending.computeIfPresent(key, (k, p) -> {
                if (!p.expiresAt().isBefore(Instant.now())) return p;
                expiryConsumer.accept(new CompletionExpiredEvent(p));
                return null;
            })
        );
    }
}
```

Note: `PendingCompletion.register()` signature drops `faultAddress` param
since fault routing no longer uses addresses.

- [ ] **Step 8: Run all core tests**

Run: `mvn --batch-mode test -pl workers-common-core`
Expected: PASS — fault handler test, orchestrator tests, static
retry tests all green.

- [ ] **Step 9: Verify full compilation**

Run: `mvn --batch-mode compile`
Expected: BUILD SUCCESS

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat(#24): extract fault/completion/retry pipeline to core with Consumer<T>

WorkerFaultPublisher, WorkflowCompletionPublisher, WorkerRetrySupport,
WorkerFaultHandler, AsyncWorkerCompletionRegistry extracted as POJOs.
EventBus.publish() replaced with Consumer<T> constructor params.
Unused Vertx inject removed from WorkerFaultHandler.

Refs casehubio/workers#24

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Batch 4: Quarkus wiring + vestigial cleanup

### Task 5: Create Quarkus producer beans, delete FaultEventHandlers

**Files:**
- Create: `workers-common/src/main/java/io/casehub/workers/common/WorkersCommonBeans.java`
- Delete: `workers-http/.../HttpWorkerFaultEventHandler.java` (use `ide_refactor_safe_delete`)
- Delete: `workers-http/.../HttpWorkerEventBusAddresses.java`
- Delete: `workers-camel/.../CamelWorkerFaultEventHandler.java`
- Delete: `workers-camel/.../CamelWorkerEventBusAddresses.java`
- Delete: `workers-github-actions/.../GitHubActionsWorkerFaultEventHandler.java`
- Delete: `workers-github-actions/.../GitHubActionsWorkerEventBusAddresses.java`
- Delete: `workers-mcp/.../McpWorkerFaultEventHandler.java`
- Delete: `workers-mcp/.../McpWorkerEventBusAddresses.java`
- Delete: `workers-script/.../ScriptWorkerFaultEventHandler.java`
- Delete: `workers-script/.../ScriptWorkerEventBusAddresses.java`
- Delete: `workers-k8s/.../K8sWorkerFaultEventHandler.java`
- Delete: `workers-k8s/.../K8sWorkerEventBusAddresses.java`
- Delete: `workers-scenario/.../ScenarioWorkerFaultEventHandler.java`
- Delete: `workers-scenario/.../ScenarioWorkerEventBusAddresses.java`
- Modify: `workers-common/pom.xml` (remove quarkus-vertx if no longer needed)

**Interfaces:**
- Consumes: All core POJOs from Tasks 1-4
- Produces: CDI beans wired with EventBus/CDI consumers

- [ ] **Step 1: Create WorkersCommonBeans**

```java
package io.casehub.workers.common;

import io.casehub.engine.common.internal.event.EventBusAddresses;
import io.casehub.engine.common.internal.event.WorkerRetriesExhaustedEvent;
import io.casehub.engine.common.internal.event.WorkflowExecutionCompleted;
import io.casehub.engine.common.spi.EventLogRepository;
import io.casehub.engine.common.spi.scheduler.WorkerExecutionManager;
import io.vertx.mutiny.core.eventbus.EventBus;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.enterprise.inject.Produces;
import jakarta.inject.Inject;

@ApplicationScoped
public class WorkersCommonBeans {

    @Inject EventBus eventBus;
    @Inject EventLogRepository eventLogRepository;
    @Inject WorkerExecutionManager workerExecutionManager;

    @Produces @ApplicationScoped
    WorkerFaultHandler faultHandler(WorkerRetrySupport retrySupport) {
        return new WorkerFaultHandler(retrySupport, workerExecutionManager,
            eventLogRepository);
    }

    @Produces @ApplicationScoped
    WorkerRetrySupport retrySupport() {
        return new WorkerRetrySupport(eventLogRepository,
            event -> eventBus.publish(EventBusAddresses.WORKER_RETRIES_EXHAUSTED, event));
    }

    @Produces @ApplicationScoped
    WorkflowCompletionPublisher completionPublisher() {
        return new WorkflowCompletionPublisher(
            event -> eventBus.publish(EventBusAddresses.WORKER_EXECUTION_FINISHED, event));
    }

    @Produces @ApplicationScoped
    WorkerFaultPublisher faultPublisher(WorkerFaultHandler handler) {
        return new WorkerFaultPublisher(
            event -> Thread.startVirtualThread(() -> handler.handleFault(event)));
    }

    @Produces @ApplicationScoped
    AsyncWorkerCompletionRegistry completionRegistry(
            jakarta.enterprise.event.Event<CompletionExpiredEvent> expiryEvents) {
        return new AsyncWorkerCompletionRegistry(
            event -> expiryEvents.fireAsync(event));
    }
}
```

- [ ] **Step 2: Delete 7 FaultEventHandler classes**

Use `ide_refactor_safe_delete` for each:

| Module | File |
|--------|------|
| workers-http | `HttpWorkerFaultEventHandler.java` |
| workers-camel | `CamelWorkerFaultEventHandler.java` |
| workers-github-actions | `GitHubActionsWorkerFaultEventHandler.java` |
| workers-mcp | `McpWorkerFaultEventHandler.java` |
| workers-script | `ScriptWorkerFaultEventHandler.java` |
| workers-k8s | `K8sWorkerFaultEventHandler.java` |
| workers-scenario | `ScenarioWorkerFaultEventHandler.java` |

- [ ] **Step 3: Delete 7 EventBusAddresses classes**

Same approach — `ide_refactor_safe_delete` for each `*EventBusAddresses.java`.
If any references remain (execution managers using the fault address
constant), update those callers first — they should now use
`faultPublisher.fault(ctx, capability, eventLogId, cause)` without
an address parameter.

- [ ] **Step 4: Add @Scheduled expiry call**

Add a scheduled method in WorkersCommonBeans (or a separate bean) that
calls `completionRegistry.expireStale()`:

```java
@ApplicationScoped
public class CompletionExpiryScheduler {

    @Inject AsyncWorkerCompletionRegistry registry;

    @Scheduled(every = "${casehub.workers.async.expiry-check-interval:5m}")
    @io.smallrye.common.annotation.Blocking
    void tick() {
        registry.expireStale();
    }
}
```

- [ ] **Step 5: Verify full build**

Run: `mvn --batch-mode install`
Expected: BUILD SUCCESS — all modules compile, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(#24): Quarkus wiring + delete 7 vestigial FaultEventHandlers

WorkersCommonBeans @Produces core POJOs with EventBus consumers.
Delete all per-module FaultEventHandler classes — fault routing
collapses to single Consumer<WorkerFaultEvent>.

Refs casehubio/workers#24

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## References

- [2026-09-25-workers-spring-boot-deployment-design.md] — design spec
- [workers-common/WorkerLifecycleOrchestrator.java:45-48] — sequential await bug
- [workers-common/WorkerRuntime.java] — Mutiny Uni interface
- [workers-common/WorkerFaultPublisher.java] — EventBus.publish pattern
- [workers-common/WorkerFaultHandler.java:28] — unused Vertx inject
- [workers-http/HttpWorkerFaultEventHandler.java] — vestigial one-liner
- [workers-http/HttpWorkerEventBusAddresses.java] — fault-address-only constants
- [platform agent-spring module] — consolidated Spring auto-config precedent
- [casehubio/workers#24] — focal issue
