# SSE Broadcaster Spring Bridge — Design

**Issue:** casehubio/engine#1214
**Branch:** issue-1214-sse-emitter-bridge
**Date:** 2026-10-06

## Problem

Three SSE broadcasters in the engine `rest/` module use SmallRye Mutiny `BroadcastProcessor` and CDI `@ObservesAsync` — Quarkus-specific APIs. The SPI interfaces (`EngineCaseApi`, `EnginePlanApi`) declare stream methods returning `Multi<T>`, coupling the api module to Quarkus. No Spring equivalents exist.

## Solution

### 1. SPI Contract Change — Multi\<T\> → Flow.Publisher\<T\>

Change `@PlatformStream` methods in `EngineCaseApi` and `EnginePlanApi` from `Multi<T>` to `java.util.concurrent.Flow.Publisher<T>`:

- `EngineCaseApi.caseStream(UUID)` → `Flow.Publisher<CaseStreamEventView>`
- `EngineCaseApi.caseLifecycle(UUID)` → `Flow.Publisher<CaseLifecycleEventView>`
- `EngineCaseApi.caseContextChange(UUID)` → `Flow.Publisher<CaseContextChangeEventView>`
- `EnginePlanApi.executionStateStream(UUID)` → `Flow.Publisher<JsonNode>`

Remove `io.smallrye.reactive:mutiny` dependency from `api/pom.xml`.

#### Empty Publisher for Stub Methods

`DefaultEngineCaseApi.caseLifecycle()` and `caseContextChange()` currently return `Multi.createFrom().empty()`. Since the Quarkus `rest/` module retains its Mutiny dependency, these stubs continue to work — `Multi<T>` IS `Flow.Publisher<T>`.

For Spring implementations, introduce a utility method in `runtime-spring/` (reusable across future SPI migrations):

```java
static <T> Flow.Publisher<T> emptyPublisher() {
    return subscriber -> {
        subscriber.onSubscribe(new Flow.Subscription() {
            @Override public void request(long n) {}
            @Override public void cancel() {}
        });
        subscriber.onComplete();
    };
}
```

### 2. Quarkus Adaptation — rest/ module

Update existing broadcasters' `stream()` return type from `Multi<T>` to `Flow.Publisher<T>`. `Multi<T>` extends `Flow.Publisher<T>` directly (verified: Mutiny 3.x type hierarchy), so the return value widens automatically — no conversion needed:

```java
public Flow.Publisher<CaseStreamEventView> stream(UUID caseId) {
    return processor.toHotStream()
        .filter(e -> caseId.equals(e.caseId()));
}
```

Mutiny operators (`filter()`, `map()`) remain available internally since the implementation works with `Multi`; only the return type widens to the JDK interface at the SPI boundary.

Update `DefaultEngineCaseApi` and `PlanService` return types to match. `PlanService.executionStateStream()` continues to use `Multi.map()` for the `ExecutionStateSnapshot` → `JsonNode` conversion — the resulting `Multi<JsonNode>` satisfies `Flow.Publisher<JsonNode>` directly.

### 3. Spring Broadcasters — runtime-spring/ module

Two new `@Component` classes in `io.casehub.engine.runtime.spring.broadcast`:

| Class | Events Observed | Stream Type |
|-------|----------------|-------------|
| `CaseStreamSpringBroadcaster` | `PlanItemStateChangedEvent`, `CaseContextUpdatedEvent` | `Flow.Publisher<CaseStreamEventView>` |
| `ExecutionStateSpringBroadcaster` | `PlanItemStateChangedEvent`, `CaseContextUpdatedEvent` | `Flow.Publisher<JsonNode>` |

`EvolutionStreamSpringBroadcaster` is out of scope — `EngineEvolutionApi` has no `@PlatformStream` method, is not `@McpDomain`-annotated, and #1132 (its origin) is closed. Building the broadcaster without the SPI is premature; if evolution streaming is later needed, file a new issue covering the full vertical (SPI, broadcaster, generated endpoint).

#### Internal Design

Each broadcaster maintains a `CopyOnWriteArrayList<ActiveStream<T>>`:

```java
record ActiveStream<T>(UUID caseId, SubmissionPublisher<T> publisher) {}
```

- `stream(UUID caseId)` creates a `SubmissionPublisher<T>`, wraps it in an `ActiveStream`, adds to the list, returns the publisher.
- `@EventListener` methods construct the view object and iterate active streams. For each matching caseId, call `publisher.offer(item, (subscriber, dropped) -> false)` — non-blocking, discards on buffer saturation. During iteration, lazily remove entries where `publisher.getNumberOfSubscribers() == 0` (dead subscriber cleanup).
- `SubmissionPublisher` configured with `ForkJoinPool.commonPool()` executor and `Flow.defaultBufferSize()` capacity.

`offer()` is used instead of `submit()` because `submit()` blocks indefinitely when any subscriber's buffer is full. Since `@EventListener` is synchronous (runs on the event-publishing thread), a blocking `submit()` would stall all event processing — not just the saturated subscriber. `offer()` with a drop handler matches the Quarkus `BackPressureFailure` catch-and-ignore semantics.

#### ExecutionStateSpringBroadcaster — additional complexity

This broadcaster produces `Flow.Publisher<JsonNode>` directly — the `objectMapper.valueToTree()` conversion happens inside the broadcaster before calling `offer()`. This avoids needing operators on `Flow.Publisher<T>` (which has only `subscribe()`) and keeps the Spring broadcaster self-contained.

Composes `ExecutionStateSnapshot` from multiple sources (`CasePlanModelSnapshotProvider`, `ExecutionSnapshotStore`, `CaseDefinitionRegistry`, `CaseInstanceRepository`). Constructor-injected dependencies, same composition logic as the Quarkus version. Also exposes `composeInitial(UUID, String)` for the initial snapshot on connection.

### 4. Generator Update — platform graphql-spring-generator/

`SpringDomainRestControllerWriter.buildStreamMethod()` currently generates Mutiny `.subscribe().with()` calls. Change to generate `Flow.Subscriber<T>` bridge on a virtual thread, matching the pattern in `rest-spring-generator/RestControllerWriter.buildMethodBody()`.

Two changes to the existing `buildStreamMethod()`:

1. **`SseEmitter(0L)` — infinite timeout.** The current code generates `new SseEmitter()` (default 30-second timeout). Change to `new SseEmitter(0L)` to match `RestControllerWriter` and prevent premature SSE connection drops. A 30-second default means streams like execution state (which only fire on case events, potentially minutes apart) silently terminate.

2. **`Flow.Subscriber` bridge with subscription lifecycle.** Replace the Mutiny `.subscribe().with()` call with a `Flow.Subscriber` that manages subscription cancellation on client disconnect:

```java
SseEmitter emitter = new SseEmitter(0L);
Thread.ofVirtual().start(() ->
    delegate.method(args).subscribe(new Flow.Subscriber<EventType>() {
        @Override public void onSubscribe(Flow.Subscription s) {
            s.request(Long.MAX_VALUE);
            emitter.onTimeout(s::cancel);
            emitter.onCompletion(s::cancel);
        }
        @Override public void onNext(EventType item) {
            try { emitter.send(item); }
            catch (Exception e) { emitter.completeWithError(e); }
        }
        @Override public void onError(Throwable t) { emitter.completeWithError(t); }
        @Override public void onComplete() { emitter.complete(); }
    })
);
return emitter;
```

The `onTimeout` and `onCompletion` callbacks cancel the `Flow.Subscription` when the client disconnects or the emitter times out. When `emitter.completeWithError(e)` is called in the `onNext` catch block (send failure), the `onCompletion` callback fires and cancels the subscription. This prevents the `SubmissionPublisher` from continuing to buffer items for dead subscribers.

The scanner (`McpDomainJandexScanner`) requires no changes — it detects streams via `@PlatformStream` annotation presence, not return type inspection.

### 5. @PlatformStream Annotation

No changes needed — `@PlatformStream` already marks streaming methods. The scanner detects streams via annotation presence and is type-agnostic. The only change is in `SpringDomainRestControllerWriter` (§4) — the generated subscriber bridge code.

## Data Flow

**Quarkus:**
```
CDI Event → @ObservesAsync → BroadcastProcessor.onNext()
  → processor.toHotStream().filter(caseId)
  → Multi<T> (IS Flow.Publisher<T>) → JAX-RS SSE endpoint
```

**Spring:**
```
Spring Event → @EventListener → iterate ActiveStreams, offer() to matching caseId
  → SubmissionPublisher<T> (implements Flow.Publisher<T>)
  → generated SseEmitter bridge (Flow.Subscriber on virtual thread)
  → SseEmitter(0L) → HTTP SSE response
```

## Error Handling

- **Back pressure:** Quarkus catches `BackPressureFailure` and ignores. Spring uses `offer()` with `(subscriber, dropped) -> false` — non-blocking discard on buffer saturation. Same semantics.
- **Client disconnect:** `emitter.onTimeout()` and `emitter.onCompletion()` callbacks cancel the `Flow.Subscription`, which signals the `SubmissionPublisher` to stop buffering. During the next `@EventListener` dispatch, lazy cleanup removes `ActiveStream` entries where `publisher.getNumberOfSubscribers() == 0`.
- **Composition failure** (ExecutionStateBroadcaster): logged at debug, event skipped — same as Quarkus.

## Scope

**In scope:**
- SPI contract change (Multi → Flow.Publisher)
- 2 Spring broadcaster components (CaseStream, ExecutionState)
- Generator update for Flow.Publisher bridge (SpringDomainRestControllerWriter)
- Generator fix: `SseEmitter(0L)` infinite timeout
- Quarkus broadcaster adaptation
- Empty publisher utility for Spring stub methods
- Unit tests for Spring broadcasters

**Out of scope:**
- EvolutionStreamSpringBroadcaster (no SPI consumer exists; #1132 closed)
- EvolutionApi SPI interface creation (file new issue if needed)
- rest-core module extraction
- Integration tests requiring full Spring Boot context

## Testing

- Unit test each Spring broadcaster: publish events → verify arrival on `stream(caseId)` publisher
- CaseId filtering: events for caseId A must not reach `stream(caseId B)`
- Cleanup: after subscriber cancel, lazy cleanup removes `ActiveStream` on next event dispatch
- Back pressure: verify `offer()` drops without blocking when buffer is full
- Generator: verify generated code compiles, uses `Flow.Subscriber` pattern, `SseEmitter(0L)`, and subscription lifecycle callbacks

## References

- `engine/rest/src/main/java/io/casehub/engine/rest/CaseStreamBroadcaster.java` — Quarkus source
- `engine/rest/src/main/java/io/casehub/engine/rest/ExecutionStateBroadcaster.java` — Quarkus source with composition
- `engine/rest/src/main/java/io/casehub/engine/rest/EvolutionStreamBroadcaster.java` — Quarkus source (orphaned, staged for #1132)
- `engine/api/src/main/java/io/casehub/api/engine/rest/EngineCaseApi.java` — SPI with @PlatformStream
- `engine/api/src/main/java/io/casehub/api/engine/rest/EnginePlanApi.java` — SPI with @PlatformStream
- `engine/runtime-spring/src/main/java/io/casehub/engine/runtime/spring/adapter/` — existing Spring adapter pattern
- `platform/rest-spring-generator/.../RestControllerWriter.java:265-296` — Flow.Publisher→SseEmitter bridge pattern
- `platform/graphql-spring-generator/.../SpringDomainRestControllerWriter.java:199-253` — current Mutiny bridge (to be updated)
- casehubio/engine#1132 — command centre conductor (EvolutionStreamBroadcaster origin)
- casehubio/engine#1206 — Spring completeness epic (parent)
