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
- `EnginePlanApi.executionStateStream(UUID)` → `Flow.Publisher<JsonNode>`

Remove `io.smallrye.reactive:mutiny` dependency from `api/pom.xml`.

#### Divergence from parent epic #1206

The parent epic spec (#1206, §1095) states: "`@PlatformStream` | Excluded from SPI — stays on concrete class (SSE is framework-specific)." The concern was that `Multi<T>` couples the SPI to Quarkus. This spec supersedes that instruction: with `Flow.Publisher<T>` (a JDK standard type in `java.util.concurrent`), the framework-specificity concern is eliminated. Keeping `@PlatformStream` on the SPI gives both runtimes a single contract for streaming, which is architecturally superior to framework-specific concrete-class streaming.

#### Stub removal — caseLifecycle and caseContextChange

`EngineCaseApi.caseLifecycle()` and `caseContextChange()` are stubs returning `Multi.createFrom().empty()`. The parent epic spec (#1206, §1095 line 174) explicitly states: "Stub implementations should be removed rather than migrated." These stubs generate dead SSE endpoints — the connection opens and immediately completes without sending events.

Remove both methods from the SPI interface (`EngineCaseApi`) and the implementation (`DefaultEngineCaseApi`). The generated REST and GraphQL controllers will stop producing the dead endpoints. Re-add when real implementations exist.

### 2. Quarkus Adaptation — rest/ module

Broadcaster `stream()` methods remain `Multi<T>` — they are internal to the `rest/` module and their callers depend on Mutiny operators (`filter()`, `map()`). Only the SPI implementation methods change their declared return types.

`Multi<T>` extends `Flow.Publisher<T>` directly (verified: Mutiny 3.x type hierarchy), so internal `Multi<T>` return values widen automatically at the SPI boundary — no conversion needed.

| Layer | Return type | Changes? |
|-------|-------------|----------|
| `CaseStreamBroadcaster.stream()` (internal, `rest/`) | `Multi<CaseStreamEventView>` | **unchanged** |
| `ExecutionStateBroadcaster.stream()` (internal, `rest/`) | `Multi<ExecutionStateSnapshot>` | **unchanged** |
| `PlanService.executionStateStream()` (internal, `rest/`) | `Multi<JsonNode>` | **unchanged** — `.map()` requires `Multi` |
| `DefaultEngineCaseApi.caseStream()` (SPI impl, `rest/`) | `Flow.Publisher<CaseStreamEventView>` | declared return type widens; returns `Multi` from broadcaster |
| `DefaultEnginePlanApi.executionStateStream()` (SPI impl, `rest/`) | `Flow.Publisher<JsonNode>` | declared return type widens; returns `Multi` from PlanService |

`PlanService.executionStateStream()` continues to use `Multi.map()` for the `ExecutionStateSnapshot` → `JsonNode` conversion — the resulting `Multi<JsonNode>` satisfies the widened `Flow.Publisher<JsonNode>` return type on `DefaultEnginePlanApi`.

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

### 4. Generator Updates — both Spring generators

Both `SpringDomainRestControllerWriter` (graphql-spring-generator) and `RestControllerWriter` (rest-spring-generator) generate `Flow.Subscriber` bridge code for SSE streams. Both need the same subscription lifecycle fix.

#### 4a. SpringDomainRestControllerWriter.buildStreamMethod()

Currently generates Mutiny `.subscribe().with()` calls. Two changes:

1. **`SseEmitter(0L)` — infinite timeout.** The current code generates `new SseEmitter()` (default 30-second timeout). Change to `new SseEmitter(0L)` to match `RestControllerWriter` and prevent premature SSE connection drops. A 30-second default means streams like execution state (which only fire on case events, potentially minutes apart) silently terminate.

2. **`Flow.Subscriber` bridge with subscription lifecycle.** Replace the Mutiny `.subscribe().with()` call with a `Flow.Subscriber` that manages subscription cancellation on client disconnect.

#### 4b. RestControllerWriter.buildMethodBody()

Already generates a `Flow.Subscriber` bridge with `new SseEmitter(0L)`. But its `onSubscribe` only calls `subscription.request(Long.MAX_VALUE)` — it lacks `onTimeout`/`onCompletion` callbacks. This is the same resource leak identified in R1-03: dead subscribers accumulate because the subscription is never cancelled on client disconnect.

#### Shared bridge pattern

Both generators produce the same bridge code after this change:

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

No changes needed — `@PlatformStream` already marks streaming methods. The scanner detects streams via annotation presence and is type-agnostic. The only changes are in the generators (§4) — the generated subscriber bridge code.

## Data Flow

**Quarkus:**
```
CDI Event → @ObservesAsync → BroadcastProcessor.onNext()
  → processor.toHotStream().filter(caseId) → Multi<T> (internal)
  → SPI impl widens to Flow.Publisher<T> → JAX-RS SSE endpoint
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
- SPI contract change (Multi → Flow.Publisher) for `caseStream` and `executionStateStream`
- Remove stub methods `caseLifecycle` and `caseContextChange` from SPI and implementation (per #1206 §1095)
- 2 Spring broadcaster components (CaseStream, ExecutionState)
- Generator update for Flow.Publisher bridge (SpringDomainRestControllerWriter)
- Generator fix: subscription lifecycle callbacks (both RestControllerWriter and SpringDomainRestControllerWriter)
- Generator fix: `SseEmitter(0L)` infinite timeout (SpringDomainRestControllerWriter)
- Quarkus SPI implementation return type widening (broadcasters unchanged)
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
- Generator (SpringDomainRestControllerWriter): verify generated code compiles, uses `Flow.Subscriber` pattern, `SseEmitter(0L)`, and subscription lifecycle callbacks
- Generator (RestControllerWriter): verify generated code includes `onTimeout`/`onCompletion` subscription cancellation callbacks

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
