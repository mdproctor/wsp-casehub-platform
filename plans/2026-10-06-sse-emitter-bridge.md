# SSE Emitter Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> subagent-driven-development (recommended) or executing-plans to
> implement this plan task-by-task. Each task follows TDD
> (test-driven-development) and uses ide-tooling for structural
> editing. Steps use checkbox (`- [ ]`) syntax for tracking.

**Focal issue:** casehubio/engine#1214 — Spring: SSE broadcasters need SseEmitter bridge
**Issue group:** #1214

**Goal:** Enable Spring SSE streaming by changing SPI stream return types from `Multi<T>` to `Flow.Publisher<T>`, writing Spring broadcaster components, and fixing the generators' SseEmitter bridge code.

**Architecture:** SPI interfaces change from Mutiny `Multi<T>` to JDK `Flow.Publisher<T>`. Quarkus implementations widen return types (Multi extends Flow.Publisher — no conversion needed). Spring broadcasters use `@EventListener` + `SubmissionPublisher<T>`. Both generators produce `Flow.Subscriber` bridge code with subscription lifecycle management.

**Tech Stack:** Java 21+ `java.util.concurrent.Flow`, `SubmissionPublisher`, Spring `@EventListener`, `SseEmitter`, JavaPoet code generation

## Global Constraints

- `platform-api/` must remain zero-dependency — `@PlatformStream` annotation unchanged
- `api/` module (engine) must not depend on SmallRye Mutiny after this change
- Generator changes apply to platform repo; SPI and broadcaster changes to engine repo
- `Multi<T>` extends `Flow.Publisher<T>` in Mutiny 3.x — verified, no conversion needed at SPI boundary
- Use `offer()` not `submit()` on `SubmissionPublisher` — `submit()` blocks the event thread
- Use `SseEmitter(0L)` — infinite timeout for long-lived streams

---

## Batch 1: Generator fixes (platform repo)

### Task 1: Fix SpringDomainRestControllerWriter stream bridge

**Files:**
- Modify: `platform/graphql-spring-generator/src/main/java/io/casehub/platform/graphql/spring/generator/SpringDomainRestControllerWriter.java:199-253` (`buildStreamMethod`)
- Test: `platform/graphql-spring-generator/src/test/java/io/casehub/platform/graphql/spring/generator/SpringDomainRestControllerWriterTest.java` (create or modify)

**Interfaces:**
- Consumes: `DomainScanResult`, `ResolvedOperation` from `generator-common`
- Produces: Generated `SseEmitter` bridge using `Flow.Subscriber` with lifecycle callbacks

- [ ] **Step 1: Add FLOW_SUBSCRIBER and FLOW_SUBSCRIPTION fields**

Add two static fields to `SpringDomainRestControllerWriter`, matching the pattern in `RestControllerWriter`:

```java
private static final ClassName FLOW_SUBSCRIBER = ClassName.get("java.util.concurrent", "Flow", "Subscriber");
private static final ClassName FLOW_SUBSCRIPTION = ClassName.get("java.util.concurrent", "Flow", "Subscription");
```

- [ ] **Step 2: Rewrite `buildStreamMethod` body (lines 247-250)**

Replace the 3 statements that use Mutiny `.subscribe().with()`:

```java
builder.addStatement("var emitter = new $T()", SSE_EMITTER);
builder.addStatement("$L.$L($L).subscribe().with(item -> { try { emitter.send(item); } catch (Exception e) { emitter.completeWithError(e); } }, emitter::completeWithError, emitter::complete)",
        fieldName, op.methodName(), args);
builder.addStatement("return emitter");
```

With the `Flow.Subscriber` bridge pattern using `SseEmitter(0L)` and lifecycle callbacks. The return type is already `SSE_EMITTER` (line 221). The new code block replaces lines 247-250:

```java
TypeName eventType = op.returnTypeName().typeArguments().get(0);

CodeBlock body = CodeBlock.builder()
        .addStatement("$T emitter = new $T(0L)", SSE_EMITTER, SSE_EMITTER)
        .beginControlFlow("$T.ofVirtual().start(() ->", Thread.class)
        .beginControlFlow("$L.$L($L).subscribe(new $T<$T>()", fieldName, op.methodName(), args, FLOW_SUBSCRIBER, eventType)
        .add("@Override\n")
        .beginControlFlow("public void onSubscribe($T subscription)", FLOW_SUBSCRIPTION)
        .addStatement("subscription.request($T.MAX_VALUE)", Long.class)
        .addStatement("emitter.onTimeout(subscription::cancel)")
        .addStatement("emitter.onCompletion(subscription::cancel)")
        .endControlFlow()
        .add("@Override\n")
        .beginControlFlow("public void onNext($T item)", eventType)
        .beginControlFlow("try")
        .addStatement("emitter.send(item)")
        .nextControlFlow("catch ($T e)", Exception.class)
        .addStatement("emitter.completeWithError(e)")
        .endControlFlow()
        .endControlFlow()
        .add("@Override\n")
        .beginControlFlow("public void onError($T t)", Throwable.class)
        .addStatement("emitter.completeWithError(t)")
        .endControlFlow()
        .add("@Override\n")
        .beginControlFlow("public void onComplete()")
        .addStatement("emitter.complete()")
        .endControlFlow()
        .endControlFlow(")") // end anonymous class + subscribe call
        .endControlFlow(")") // end lambda + Thread.start
        .addStatement("return emitter")
        .build();
builder.addCode(body);
```

Note: `op.returnTypeName()` may need to be `op.returnType()` — check the `ResolvedOperation` record's field name. The key is extracting the type argument from the `Flow.Publisher<T>` or `Multi<T>` parameterized type.

- [ ] **Step 3: Run generator tests**

Run: `mvn --batch-mode test -pl graphql-spring-generator -f /Users/mdproctor/claude/casehub/slots/198/platform/pom.xml`
Expected: PASS — generated code uses Flow.Subscriber pattern.

If no tests exist for `buildStreamMethod`, write a test that creates a `DomainScanResult` with a `STREAM` operation and verifies the generated Java source contains `Flow.Subscriber`, `SseEmitter(0L)`, `onTimeout`, and `onCompletion`.

- [ ] **Step 4: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/platform add graphql-spring-generator/
git -C /Users/mdproctor/claude/casehub/slots/198/platform commit -m "fix(#1214): replace Mutiny subscribe with Flow.Subscriber in graphql-spring-generator

Change buildStreamMethod to generate Flow.Subscriber bridge with
SseEmitter(0L) infinite timeout and onTimeout/onCompletion subscription
cancellation callbacks. Removes runtime dependency on SmallRye Mutiny
in generated Spring controllers.

Refs casehubio/engine#1214"
```

### Task 2: Fix RestControllerWriter subscription lifecycle

**Files:**
- Modify: `platform/rest-spring-generator/src/main/java/io/casehub/platform/rest/spring/generator/RestControllerWriter.java:274-276` (`onSubscribe` block in `buildMethodBody`)

**Interfaces:**
- Consumes: `RestMethodDescriptor` from rest-spring-generator
- Produces: Generated `Flow.Subscriber` with `onTimeout`/`onCompletion` callbacks

- [ ] **Step 1: Add lifecycle callbacks to onSubscribe**

In `RestControllerWriter.buildMethodBody()` (line 274-276), the `onSubscribe` block currently only has:
```java
.addStatement("subscription.request($T.MAX_VALUE)", Long.class)
```

Add two more statements after it:
```java
.addStatement("emitter.onTimeout(subscription::cancel)")
.addStatement("emitter.onCompletion(subscription::cancel)")
```

- [ ] **Step 2: Run generator tests**

Run: `mvn --batch-mode test -pl rest-spring-generator -f /Users/mdproctor/claude/casehub/slots/198/platform/pom.xml`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/platform add rest-spring-generator/
git -C /Users/mdproctor/claude/casehub/slots/198/platform commit -m "fix(#1214): add subscription lifecycle callbacks in rest-spring-generator

Add onTimeout and onCompletion subscription cancellation to generated
Flow.Subscriber bridge. Prevents SubmissionPublisher resource leak when
SSE clients disconnect.

Refs casehubio/engine#1214"
```

---

## Batch 2: SPI contract change and stub removal (engine repo)

### Task 3: Change SPI stream return types to Flow.Publisher

**Files:**
- Modify: `engine/api/src/main/java/io/casehub/api/engine/rest/EngineCaseApi.java:36,75-82` (remove Multi import, change return types, remove stub methods)
- Modify: `engine/api/src/main/java/io/casehub/api/engine/rest/EnginePlanApi.java:22,47-48` (remove Multi import, change return type)
- Modify: `engine/api/pom.xml` (remove `io.smallrye.reactive:mutiny` dependency)

**Interfaces:**
- Consumes: Nothing
- Produces: `EngineCaseApi.caseStream(UUID) → Flow.Publisher<CaseStreamEventView>`, `EnginePlanApi.executionStateStream(UUID) → Flow.Publisher<JsonNode>`

- [ ] **Step 1: Update EngineCaseApi**

In `EngineCaseApi.java`:
1. Remove `import io.smallrye.mutiny.Multi;`
2. Add `import java.util.concurrent.Flow;`
3. Change `caseStream` return type:
   ```java
   @PlatformStream("Live case event stream")
   Flow.Publisher<CaseStreamEventView> caseStream(@PathParam UUID caseId);
   ```
4. Delete `caseLifecycle` method (lines 78-79) — stub returning empty
5. Delete `caseContextChange` method (lines 81-82) — stub returning empty
6. Remove unused imports: `CaseLifecycleEventView`, `CaseContextChangeEventView`

- [ ] **Step 2: Update EnginePlanApi**

In `EnginePlanApi.java`:
1. Remove `import io.smallrye.mutiny.Multi;`
2. Add `import java.util.concurrent.Flow;`
3. Change `executionStateStream` return type:
   ```java
   @PlatformStream("Live execution state updates")
   Flow.Publisher<JsonNode> executionStateStream(@PathParam UUID caseId);
   ```

- [ ] **Step 3: Remove Mutiny dependency from api/pom.xml**

Remove the `io.smallrye.reactive:mutiny` dependency from `engine/api/pom.xml` (around line 50-51).

- [ ] **Step 4: Update DefaultEngineCaseApi**

In `DefaultEngineCaseApi.java`:
1. Change `caseStream` return type to `Flow.Publisher<CaseStreamEventView>` (the internal `caseStreamBroadcaster.stream(caseId)` returns `Multi<T>` which IS-A `Flow.Publisher<T>` — no conversion needed)
2. Delete `caseLifecycle` method (lines 92-94)
3. Delete `caseContextChange` method (lines 97-99)
4. Remove unused imports: `Multi`, `CaseLifecycleEventView`, `CaseContextChangeEventView`
5. Add `import java.util.concurrent.Flow;`

- [ ] **Step 5: Update DefaultEnginePlanApi**

In `DefaultEnginePlanApi.java`:
1. Change `executionStateStream` return type to `Flow.Publisher<JsonNode>` (the internal `planService.executionStateStream(caseId)` returns `Multi<JsonNode>` which IS-A `Flow.Publisher<JsonNode>`)
2. Remove `import io.smallrye.mutiny.Multi;`
3. Add `import java.util.concurrent.Flow;`

- [ ] **Step 6: Compile check**

Run: `mvn --batch-mode compile -pl api,rest -f /Users/mdproctor/claude/casehub/slots/198/engine/pom.xml -am`
Expected: PASS — `Multi<T>` IS-A `Flow.Publisher<T>`, so internal code using Multi operators continues to work.

If compilation fails because `PlanService.executionStateStream()` still declares `Multi<JsonNode>` and the return from `DefaultEnginePlanApi.executionStateStream()` can't widen — check the exact type hierarchy. `Multi<T> extends Publisher<T>` may need explicit cast or the PlanService return to stay as Multi (which widens automatically).

- [ ] **Step 7: Run tests**

Run: `mvn --batch-mode test -pl api,rest -f /Users/mdproctor/claude/casehub/slots/198/engine/pom.xml -am`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/engine add api/ rest/
git -C /Users/mdproctor/claude/casehub/slots/198/engine commit -m "refactor(#1214): change SPI stream return types from Multi to Flow.Publisher

EngineCaseApi.caseStream and EnginePlanApi.executionStateStream now return
Flow.Publisher<T> — JDK standard type, no Quarkus coupling. Multi<T>
extends Flow.Publisher<T> so Quarkus impls widen automatically.

Remove caseLifecycle and caseContextChange stubs (empty Multi, dead
endpoints). Remove mutiny dependency from api module.

Refs #1214"
```

---

## Batch 3: Spring broadcasters (engine repo)

### Task 4: CaseStreamSpringBroadcaster

**Files:**
- Create: `engine/runtime-spring/src/main/java/io/casehub/engine/runtime/spring/broadcast/CaseStreamSpringBroadcaster.java`
- Test: `engine/runtime-spring/src/test/java/io/casehub/engine/runtime/spring/broadcast/CaseStreamSpringBroadcasterTest.java`

**Interfaces:**
- Consumes: `PlanItemStateChangedEvent`, `CaseContextUpdatedEvent` (CDI event records from `engine/common-core`), `CaseStreamEventView` (from `engine/api`)
- Produces: `Flow.Publisher<CaseStreamEventView> stream(UUID caseId)` — used by Spring SPI impl of `EngineCaseApi`

- [ ] **Step 1: Write failing test**

```java
package io.casehub.engine.runtime.spring.broadcast;

import static org.junit.jupiter.api.Assertions.*;

import io.casehub.api.model.TaskStatus;
import io.casehub.api.view.CaseStreamEventView;
import io.casehub.engine.common.spi.event.CaseContextUpdatedEvent;
import io.casehub.engine.common.spi.event.PlanItemStateChangedEvent;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Flow;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

class CaseStreamSpringBroadcasterTest {

    @Test
    void planItemEventDeliveredToStream() throws Exception {
        var broadcaster = new CaseStreamSpringBroadcaster();
        UUID caseId = UUID.randomUUID();

        List<CaseStreamEventView> received = new ArrayList<>();
        CountDownLatch latch = new CountDownLatch(1);

        broadcaster.stream(caseId).subscribe(new Flow.Subscriber<>() {
            Flow.Subscription sub;
            @Override public void onSubscribe(Flow.Subscription s) { sub = s; s.request(Long.MAX_VALUE); }
            @Override public void onNext(CaseStreamEventView item) { received.add(item); latch.countDown(); }
            @Override public void onError(Throwable t) { fail(t); }
            @Override public void onComplete() {}
        });

        broadcaster.onPlanItemChanged(new PlanItemStateChangedEvent(
                caseId, "pi-1", "analysis", TaskStatus.PENDING, TaskStatus.RUNNING, "t1"));

        assertTrue(latch.await(2, TimeUnit.SECONDS));
        assertEquals(1, received.size());
        assertEquals(caseId, received.get(0).caseId());
        assertEquals("plan-item", received.get(0).eventType());
    }

    @Test
    void filtersByCaseId() throws Exception {
        var broadcaster = new CaseStreamSpringBroadcaster();
        UUID target = UUID.randomUUID();
        UUID other = UUID.randomUUID();

        List<CaseStreamEventView> received = new ArrayList<>();
        CountDownLatch latch = new CountDownLatch(1);

        broadcaster.stream(target).subscribe(new Flow.Subscriber<>() {
            @Override public void onSubscribe(Flow.Subscription s) { s.request(Long.MAX_VALUE); }
            @Override public void onNext(CaseStreamEventView item) { received.add(item); latch.countDown(); }
            @Override public void onError(Throwable t) { fail(t); }
            @Override public void onComplete() {}
        });

        broadcaster.onPlanItemChanged(new PlanItemStateChangedEvent(
                other, "pi-other", "review", TaskStatus.PENDING, TaskStatus.RUNNING, "t1"));
        broadcaster.onPlanItemChanged(new PlanItemStateChangedEvent(
                target, "pi-1", "analysis", TaskStatus.RUNNING, TaskStatus.COMPLETED, "t1"));

        assertTrue(latch.await(2, TimeUnit.SECONDS));
        assertEquals(1, received.size());
        assertEquals(target, received.get(0).caseId());
    }

    @Test
    void contextEventDelivered() throws Exception {
        var broadcaster = new CaseStreamSpringBroadcaster();
        UUID caseId = UUID.randomUUID();

        List<CaseStreamEventView> received = new ArrayList<>();
        CountDownLatch latch = new CountDownLatch(1);

        broadcaster.stream(caseId).subscribe(new Flow.Subscriber<>() {
            @Override public void onSubscribe(Flow.Subscription s) { s.request(Long.MAX_VALUE); }
            @Override public void onNext(CaseStreamEventView item) { received.add(item); latch.countDown(); }
            @Override public void onError(Throwable t) { fail(t); }
            @Override public void onComplete() {}
        });

        broadcaster.onContextUpdated(new CaseContextUpdatedEvent(caseId, "working", "t1"));

        assertTrue(latch.await(2, TimeUnit.SECONDS));
        assertEquals(1, received.size());
        assertEquals("context", received.get(0).eventType());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl runtime-spring -Dtest=CaseStreamSpringBroadcasterTest -f /Users/mdproctor/claude/casehub/slots/198/engine/pom.xml -am`
Expected: FAIL — `CaseStreamSpringBroadcaster` class does not exist.

- [ ] **Step 3: Implement CaseStreamSpringBroadcaster**

```java
package io.casehub.engine.runtime.spring.broadcast;

import io.casehub.api.view.CaseStreamEventView;
import io.casehub.engine.common.spi.event.CaseContextUpdatedEvent;
import io.casehub.engine.common.spi.event.PlanItemStateChangedEvent;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.Flow;
import java.util.concurrent.SubmissionPublisher;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

@Component
public class CaseStreamSpringBroadcaster {

    private record ActiveStream(UUID caseId, SubmissionPublisher<CaseStreamEventView> publisher) {}

    private final CopyOnWriteArrayList<ActiveStream> streams = new CopyOnWriteArrayList<>();

    @EventListener
    public void onPlanItemChanged(PlanItemStateChangedEvent event) {
        var view = new CaseStreamEventView(
                event.caseId(),
                "plan-item",
                Map.of(
                        "planItemId", event.planItemId(),
                        "bindingName", event.bindingName(),
                        "previousStatus",
                                event.previousStatus() != null ? event.previousStatus().name() : "NONE",
                        "newStatus", event.newStatus().name()));
        dispatch(event.caseId(), view);
    }

    @EventListener
    public void onContextUpdated(CaseContextUpdatedEvent event) {
        var view = new CaseStreamEventView(
                event.caseId(), "context", Map.of("changedLayer", event.changedLayer()));
        dispatch(event.caseId(), view);
    }

    public Flow.Publisher<CaseStreamEventView> stream(UUID caseId) {
        var publisher = new SubmissionPublisher<CaseStreamEventView>();
        streams.add(new ActiveStream(caseId, publisher));
        return publisher;
    }

    private void dispatch(UUID caseId, CaseStreamEventView view) {
        streams.removeIf(s -> s.publisher().getNumberOfSubscribers() == 0 && s.publisher().isClosed());
        for (var s : streams) {
            if (caseId.equals(s.caseId())) {
                s.publisher().offer(view, (subscriber, dropped) -> false);
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl runtime-spring -Dtest=CaseStreamSpringBroadcasterTest -f /Users/mdproctor/claude/casehub/slots/198/engine/pom.xml -am`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/engine add runtime-spring/
git -C /Users/mdproctor/claude/casehub/slots/198/engine commit -m "feat(#1214): add CaseStreamSpringBroadcaster

Spring @EventListener equivalent of CaseStreamBroadcaster. Maintains
SubmissionPublisher registry per caseId, dispatches via offer() (non-blocking,
discard on saturation). Lazy cleanup of dead subscribers.

Refs #1214"
```

### Task 5: ExecutionStateSpringBroadcaster

**Files:**
- Create: `engine/runtime-spring/src/main/java/io/casehub/engine/runtime/spring/broadcast/ExecutionStateSpringBroadcaster.java`
- Test: `engine/runtime-spring/src/test/java/io/casehub/engine/runtime/spring/broadcast/ExecutionStateSpringBroadcasterTest.java`

**Interfaces:**
- Consumes: `PlanItemStateChangedEvent`, `CaseContextUpdatedEvent`, `CasePlanModelSnapshotProvider`, `ExecutionSnapshotStore`, `CaseDefinitionRegistry`, `CaseInstanceRepository`, `ObjectMapper`
- Produces: `Flow.Publisher<JsonNode> stream(UUID caseId)`, `JsonNode composeInitial(UUID caseId, String tenancyId)` — used by Spring SPI impl of `EnginePlanApi`

- [ ] **Step 1: Write failing test**

```java
package io.casehub.engine.runtime.spring.broadcast;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.casehub.api.model.TaskStatus;
import io.casehub.engine.common.spi.CaseDefinitionRegistry;
import io.casehub.engine.common.spi.CaseInstanceRepository;
import io.casehub.engine.common.spi.event.PlanItemStateChangedEvent;
import io.casehub.engine.common.spi.recovery.ExecutionSnapshotStore;
import io.casehub.engine.plan.execution.CasePlanModelSnapshotProvider;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Flow;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

class ExecutionStateSpringBroadcasterTest {

    @Test
    void planItemEventTriggersJsonSnapshot() throws Exception {
        var planModelProvider = mock(CasePlanModelSnapshotProvider.class);
        var snapshotStore = mock(ExecutionSnapshotStore.class);
        var definitionRegistry = mock(CaseDefinitionRegistry.class);
        var caseInstanceRepository = mock(CaseInstanceRepository.class);
        var objectMapper = new ObjectMapper();

        when(planModelProvider.getSnapshot(any(), any())).thenReturn(Optional.empty());
        when(snapshotStore.getDagPlan(any(), any())).thenReturn(Optional.empty());
        when(snapshotStore.getDagResult(any(), any())).thenReturn(Optional.empty());

        var broadcaster = new ExecutionStateSpringBroadcaster(
                planModelProvider, snapshotStore, definitionRegistry,
                caseInstanceRepository, objectMapper);

        UUID caseId = UUID.randomUUID();
        List<JsonNode> received = new ArrayList<>();
        CountDownLatch latch = new CountDownLatch(1);

        broadcaster.stream(caseId).subscribe(new Flow.Subscriber<>() {
            @Override public void onSubscribe(Flow.Subscription s) { s.request(Long.MAX_VALUE); }
            @Override public void onNext(JsonNode item) { received.add(item); latch.countDown(); }
            @Override public void onError(Throwable t) { fail(t); }
            @Override public void onComplete() {}
        });

        broadcaster.onPlanItemChanged(new PlanItemStateChangedEvent(
                caseId, "pi-1", "analysis", TaskStatus.PENDING, TaskStatus.RUNNING, "t1"));

        assertTrue(latch.await(2, TimeUnit.SECONDS));
        assertEquals(1, received.size());
        assertTrue(received.get(0).isObject());
    }

    @Test
    void filtersByCaseId() throws Exception {
        var planModelProvider = mock(CasePlanModelSnapshotProvider.class);
        var snapshotStore = mock(ExecutionSnapshotStore.class);
        var definitionRegistry = mock(CaseDefinitionRegistry.class);
        var caseInstanceRepository = mock(CaseInstanceRepository.class);
        var objectMapper = new ObjectMapper();

        when(planModelProvider.getSnapshot(any(), any())).thenReturn(Optional.empty());
        when(snapshotStore.getDagPlan(any(), any())).thenReturn(Optional.empty());
        when(snapshotStore.getDagResult(any(), any())).thenReturn(Optional.empty());

        var broadcaster = new ExecutionStateSpringBroadcaster(
                planModelProvider, snapshotStore, definitionRegistry,
                caseInstanceRepository, objectMapper);

        UUID target = UUID.randomUUID();
        UUID other = UUID.randomUUID();

        List<JsonNode> received = new ArrayList<>();
        CountDownLatch latch = new CountDownLatch(1);

        broadcaster.stream(target).subscribe(new Flow.Subscriber<>() {
            @Override public void onSubscribe(Flow.Subscription s) { s.request(Long.MAX_VALUE); }
            @Override public void onNext(JsonNode item) { received.add(item); latch.countDown(); }
            @Override public void onError(Throwable t) { fail(t); }
            @Override public void onComplete() {}
        });

        broadcaster.onPlanItemChanged(new PlanItemStateChangedEvent(
                other, "pi-other", "review", TaskStatus.PENDING, TaskStatus.RUNNING, "t1"));
        broadcaster.onPlanItemChanged(new PlanItemStateChangedEvent(
                target, "pi-1", "analysis", TaskStatus.RUNNING, TaskStatus.COMPLETED, "t1"));

        assertTrue(latch.await(2, TimeUnit.SECONDS));
        assertEquals(1, received.size());
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mvn --batch-mode test -pl runtime-spring -Dtest=ExecutionStateSpringBroadcasterTest -f /Users/mdproctor/claude/casehub/slots/198/engine/pom.xml -am`
Expected: FAIL — class does not exist.

- [ ] **Step 3: Implement ExecutionStateSpringBroadcaster**

Mirror `ExecutionStateBroadcaster` composition logic but output `JsonNode` directly (avoids needing Multi operators). Constructor-injected dependencies:

```java
package io.casehub.engine.runtime.spring.broadcast;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.casehub.api.model.CaseDefinition;
import io.casehub.engine.common.spi.CaseDefinitionRegistry;
import io.casehub.engine.common.spi.CaseInstanceRepository;
import io.casehub.engine.common.spi.event.CaseContextUpdatedEvent;
import io.casehub.engine.common.spi.event.PlanItemStateChangedEvent;
import io.casehub.engine.common.spi.recovery.ExecutionSnapshotStore;
import io.casehub.engine.plan.execution.CasePlanModelSnapshotProvider;
import io.casehub.engine.rest.dto.ExecutionStateSnapshot;
import java.util.UUID;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.Flow;
import java.util.concurrent.SubmissionPublisher;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

@Component
public class ExecutionStateSpringBroadcaster {

    private static final Logger LOG = LoggerFactory.getLogger(ExecutionStateSpringBroadcaster.class);

    private record ActiveStream(UUID caseId, SubmissionPublisher<JsonNode> publisher) {}

    private final CopyOnWriteArrayList<ActiveStream> streams = new CopyOnWriteArrayList<>();
    private final CasePlanModelSnapshotProvider planModelProvider;
    private final ExecutionSnapshotStore snapshotStore;
    private final CaseDefinitionRegistry definitionRegistry;
    private final CaseInstanceRepository caseInstanceRepository;
    private final ObjectMapper objectMapper;

    public ExecutionStateSpringBroadcaster(
            CasePlanModelSnapshotProvider planModelProvider,
            ExecutionSnapshotStore snapshotStore,
            CaseDefinitionRegistry definitionRegistry,
            CaseInstanceRepository caseInstanceRepository,
            ObjectMapper objectMapper) {
        this.planModelProvider = planModelProvider;
        this.snapshotStore = snapshotStore;
        this.definitionRegistry = definitionRegistry;
        this.caseInstanceRepository = caseInstanceRepository;
        this.objectMapper = objectMapper;
    }

    @EventListener
    public void onPlanItemChanged(PlanItemStateChangedEvent event) {
        compose(event.caseId(), event.tenancyId());
    }

    @EventListener
    public void onContextUpdated(CaseContextUpdatedEvent event) {
        compose(event.caseId(), event.tenancyId());
    }

    public Flow.Publisher<JsonNode> stream(UUID caseId) {
        var publisher = new SubmissionPublisher<JsonNode>();
        streams.add(new ActiveStream(caseId, publisher));
        return publisher;
    }

    public JsonNode composeInitial(UUID caseId, String tenancyId) {
        var snapshot = composeSnapshot(caseId, tenancyId);
        return snapshot != null ? objectMapper.valueToTree(snapshot) : null;
    }

    private void compose(UUID caseId, String tenancyId) {
        try {
            var snapshot = composeSnapshot(caseId, tenancyId);
            if (snapshot == null) return;
            JsonNode json = objectMapper.valueToTree(snapshot);
            dispatch(caseId, json);
        } catch (Exception e) {
            LOG.debug("Failed to compose execution state for case {}: {}", caseId, e.getMessage());
        }
    }

    private ExecutionStateSnapshot composeSnapshot(UUID caseId, String tenancyId) {
        var planModel = planModelProvider.getSnapshot(caseId, tenancyId).orElse(null);
        var dagPlan = snapshotStore.getDagPlan(caseId, tenancyId).orElse(null);
        var dagResult = snapshotStore.getDagResult(caseId, tenancyId).orElse(null);
        if (planModel == null && dagPlan == null && dagResult == null) return null;
        CaseDefinition definition = resolveDefinition(caseId, tenancyId);
        return ExecutionStateSnapshot.compose(caseId, planModel, dagPlan, dagResult, definition);
    }

    private CaseDefinition resolveDefinition(UUID caseId, String tenancyId) {
        try {
            return caseInstanceRepository
                    .findByUuid(caseId, tenancyId)
                    .filter(instance -> instance.getCaseMetaModel() != null)
                    .map(instance -> definitionRegistry.getCaseDefinition(instance.getCaseMetaModel()))
                    .orElse(null);
        } catch (Exception ignored) {}
        return null;
    }

    private void dispatch(UUID caseId, JsonNode json) {
        streams.removeIf(s -> s.publisher().getNumberOfSubscribers() == 0 && s.publisher().isClosed());
        for (var s : streams) {
            if (caseId.equals(s.caseId())) {
                s.publisher().offer(json, (subscriber, dropped) -> false);
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mvn --batch-mode test -pl runtime-spring -Dtest=ExecutionStateSpringBroadcasterTest -f /Users/mdproctor/claude/casehub/slots/198/engine/pom.xml -am`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C /Users/mdproctor/claude/casehub/slots/198/engine add runtime-spring/
git -C /Users/mdproctor/claude/casehub/slots/198/engine commit -m "feat(#1214): add ExecutionStateSpringBroadcaster

Spring @EventListener equivalent of ExecutionStateBroadcaster. Composes
ExecutionStateSnapshot from multiple sources, converts to JsonNode via
ObjectMapper, dispatches via SubmissionPublisher.offer().

Refs #1214"
```

---

## Batch 4: Regenerate and verify (engine repo)

### Task 6: Regenerate Spring controllers and verify compilation

**Files:**
- Regenerated: `engine/runtime-spring/target/generated-sources/graphql-spring-generator/` (all controllers)
- Verify: Generated `EngineCasesRestController` no longer has `caseLifecycle`/`caseContextChange` methods and `caseStream` uses `Flow.Subscriber`

- [ ] **Step 1: Rebuild platform install to pick up generator changes**

Run: `mvn --batch-mode install -DskipTests -f /Users/mdproctor/claude/casehub/slots/198/platform/pom.xml`
Expected: PASS — platform installs with updated generators.

- [ ] **Step 2: Regenerate engine Spring controllers**

Run: `mvn --batch-mode generate-sources -pl runtime-spring -f /Users/mdproctor/claude/casehub/slots/198/engine/pom.xml -am`
Expected: Generated controllers use `Flow.Subscriber` bridge, no Mutiny imports.

- [ ] **Step 3: Verify generated code**

Read the generated `EngineCasesRestController.java` and `EnginePlanRestController.java` in `runtime-spring/target/generated-sources/graphql-spring-generator/`. Verify:
- `caseStream` method uses `Flow.Subscriber`, `SseEmitter(0L)`, `onTimeout`, `onCompletion`
- `caseLifecycle` and `caseContextChange` methods are absent
- `executionStateStream` method uses the same `Flow.Subscriber` pattern
- No `io.smallrye.mutiny` imports

- [ ] **Step 4: Full compile check**

Run: `mvn --batch-mode compile -f /Users/mdproctor/claude/casehub/slots/198/engine/pom.xml`
Expected: PASS — everything compiles including generated code.

- [ ] **Step 5: Full test run**

Run: `mvn --batch-mode test -f /Users/mdproctor/claude/casehub/slots/198/engine/pom.xml`
Expected: PASS

- [ ] **Step 6: Commit (if any source changes were needed)**

Only commit if manual adjustments were needed. Generated code is not committed.

## References

- [2026-10-06-sse-emitter-bridge-design.md] — design spec this plan implements
- `engine/rest/src/main/java/io/casehub/engine/rest/CaseStreamBroadcaster.java` — Quarkus source (event→view mapping copied)
- `engine/rest/src/main/java/io/casehub/engine/rest/ExecutionStateBroadcaster.java` — Quarkus source (composition logic mirrored)
- `engine/rest/src/test/java/io/casehub/engine/rest/ExecutionStateBroadcasterTest.java` — test pattern reference
- `platform/graphql-spring-generator/.../SpringDomainRestControllerWriter.java:199-253` — buildStreamMethod to update
- `platform/rest-spring-generator/.../RestControllerWriter.java:265-296` — Flow.Publisher bridge pattern (lifecycle fix)
- `platform/generator-common/.../McpDomainJandexScanner.java:91-97` — stream detection (annotation-based, type-agnostic)
- casehubio/engine#1214 — focal issue
- casehubio/engine#1206 — parent Spring completeness epic
