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

### 2. Quarkus Adaptation — rest/ module

Update existing broadcasters' `stream()` return type from `Multi<T>` to `Flow.Publisher<T>`. Internally wrap with `multi.convert().toPublisher()`:

```java
public Flow.Publisher<CaseStreamEventView> stream(UUID caseId) {
    return processor.toHotStream()
        .filter(e -> caseId.equals(e.caseId()))
        .convert().toPublisher();
}
```

Update `DefaultEngineCaseApi` and `PlanService` return types to match.

### 3. Spring Broadcasters — runtime-spring/ module

Three new `@Component` classes in `io.casehub.engine.runtime.spring.broadcast`:

| Class | Events Observed | Stream Type |
|-------|----------------|-------------|
| `CaseStreamSpringBroadcaster` | `PlanItemStateChangedEvent`, `CaseContextUpdatedEvent` | `Flow.Publisher<CaseStreamEventView>` |
| `ExecutionStateSpringBroadcaster` | `PlanItemStateChangedEvent`, `CaseContextUpdatedEvent` | `Flow.Publisher<ExecutionStateSnapshot>` |
| `EvolutionStreamSpringBroadcaster` | `CircuitBreakerStateChangedEvent`, `ComplianceLevelChangedEvent`, `RegressionDetectedEvent`, `TickEvaluatedEvent` | `Flow.Publisher<EvolutionEvent>` |

#### Internal Design

Each broadcaster maintains a `CopyOnWriteArrayList<ActiveStream<T>>`:

```java
record ActiveStream<T>(UUID caseId, SubmissionPublisher<T> publisher) {}
```

- `stream(UUID caseId)` creates a `SubmissionPublisher<T>`, wraps it in an `ActiveStream`, adds to the list, returns the publisher. Registers an `onClose` handler to remove from the list.
- `@EventListener` methods construct the view object and iterate active streams, calling `publisher.submit(item)` on streams matching the event's caseId.
- `SubmissionPublisher` configured with `Flow.defaultBufferSize()` and `DISCARD` handler for overflow — matches the Quarkus `BackPressureFailure` catch-and-ignore pattern.

#### ExecutionStateSpringBroadcaster — additional complexity

This broadcaster composes `ExecutionStateSnapshot` from multiple sources (`CasePlanModelSnapshotProvider`, `ExecutionSnapshotStore`, `CaseDefinitionRegistry`, `CaseInstanceRepository`). Constructor-injected dependencies, same composition logic as the Quarkus version. Also exposes `composeInitial(UUID, String)` for the initial snapshot on connection.

### 4. Generator Update — platform graphql-spring-generator/

`SpringDomainRestControllerWriter.buildStreamMethod()` currently generates Mutiny `.subscribe().with()` calls. Change to generate `Flow.Subscriber<T>` bridge on a virtual thread, matching the pattern already in `rest-spring-generator/RestControllerWriter`:

```java
SseEmitter emitter = new SseEmitter(0L);
Thread.ofVirtual().start(() ->
    delegate.method(args).subscribe(new Flow.Subscriber<EventType>() {
        @Override public void onSubscribe(Flow.Subscription s) { s.request(Long.MAX_VALUE); }
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

Also update the scanner to detect `Flow.Publisher<T>` as a stream return type (currently it checks for `Multi<T>` via Mutiny-specific subscribe API).

### 5. @PlatformStream Annotation

No changes needed — `@PlatformStream` already marks streaming methods. The generators need to recognize `Flow.Publisher<T>` as the stream return type instead of (or in addition to) `Multi<T>`.

## Data Flow

**Quarkus:**
```
CDI Event → @ObservesAsync → BroadcastProcessor.onNext()
  → processor.toHotStream().filter(caseId).convert().toPublisher()
  → Flow.Publisher<T> → JAX-RS SSE endpoint (Multi from Publisher)
```

**Spring:**
```
Spring Event → @EventListener → iterate ActiveStreams, submit to matching caseId
  → SubmissionPublisher<T> (implements Flow.Publisher<T>)
  → generated SseEmitter bridge (Flow.Subscriber on virtual thread)
  → SseEmitter → HTTP SSE response
```

## Error Handling

- **Back pressure:** Quarkus catches `BackPressureFailure` and ignores. Spring uses `SubmissionPublisher` with discard-on-overflow — same semantics.
- **Client disconnect:** SseEmitter timeout/completion triggers publisher close. `ActiveStream` cleanup via `onClose` handler on the `SubmissionPublisher`.
- **Composition failure** (ExecutionStateBroadcaster): logged at debug, event skipped — same as Quarkus.

## Scope

**In scope:**
- SPI contract change (Multi → Flow.Publisher)
- 3 Spring broadcaster components
- Generator update for Flow.Publisher bridge
- Quarkus broadcaster adaptation
- Unit tests for Spring broadcasters

**Out of scope:**
- EvolutionApi SPI interface creation (separate issue, command centre conductor #1132)
- rest-core module extraction
- Integration tests requiring full Spring Boot context

## Testing

- Unit test each Spring broadcaster: publish events → verify arrival on `stream(caseId)` publisher
- CaseId filtering: events for caseId A must not reach `stream(caseId B)`
- Cleanup: after publisher close, broadcaster releases references
- Generator: verify generated code compiles and uses Flow.Subscriber pattern

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
