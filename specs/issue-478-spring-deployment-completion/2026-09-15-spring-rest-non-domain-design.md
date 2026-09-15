# Spring REST Controllers for Non-Domain @Path Resources — Design Spec

**Issue:** casehubio/parent#483
**Date:** 2026-09-15

## Goal

Create Spring @RestController equivalents for 6 hand-written JAX-RS @Path resources that are not covered by @McpDomain → graphql-spring-generator. The rest-spring-generator cannot handle these (single-delegate limit, no Response/Instance<>/@Context support).

## Approach

Core-extract business logic from each resource into a framework-neutral POJO in the appropriate -core module. The JAX-RS resource becomes a thin wrapper. A hand-written Spring @RestController in platform-spring delegates to the same POJO. Both frameworks share identical business logic.

## Per-Resource Plan

### 1. EventTypeResource (subscriptions → subscriptions-core)

**Current:** Single GET, 1 dep (`EventTypeRegistry`), returns `Set<EventTypeDescriptor>`.

**Extraction:** Create `EventTypeService` in subscriptions-core. Constructor takes `EventTypeRegistry`. Single method: `Set<EventTypeDescriptor> listEventTypes()`.

**Spring controller:** `EventTypeRestController` — `@GetMapping("/subscriptions/event-types")`, delegates to `EventTypeService`.

**JAX-RS resource:** Becomes a thin wrapper delegating to `EventTypeService`.

### 2. SubscriptionResource (subscriptions → subscriptions-core)

**Current:** 3 deps (`SubscriptionStore`, `CurrentPrincipal`, `ExpressionEngineRegistry`), 8 methods, returns `Response` throughout, uses `@RunOnVirtualThread`, `@DefaultValue`.

**Extraction:** Create `SubscriptionService` in subscriptions-core. Constructor takes all 3 deps. Methods return domain types or `Optional<>` — no `Response` objects. Authorization checks (system scope guard) stay in the service. Expression extraction logic (`extractExpression` with `instanceof` pattern matching) moves to the service.

Methods:
- `Subscription create(SubscriptionInput)` — throws on auth failure or invalid filter
- `SubscriptionPage list(Boolean enabled, SubscriptionScope scope, String cursor, int limit)`
- `Optional<Subscription> getById(String id)`
- `Optional<Subscription> update(String id, SubscriptionUpdate)`
- `boolean delete(String id)`
- `Optional<Subscription> enable(String id)`
- `Optional<Subscription> disable(String id)`

**Spring controller:** `SubscriptionRestController` — maps methods to `@GetMapping`/`@PostMapping`/`@PatchMapping`/`@DeleteMapping` with `ResponseEntity` wrapping (201 for create, 404 for missing, 204 for delete).

**JAX-RS resource:** Becomes a thin wrapper converting service returns to `Response`.

### 3. PreferenceSchemaResource (preferences-editor → preferences-editor-core)

**Current:** 1 dep (`PreferenceSchemaRegistry`), 1 method with ETag conditional GET via `@Context Request`.

**Extraction:** Create `PreferenceSchemaService` in preferences-editor-core. Constructor takes `PreferenceSchemaRegistry`. Method: `SchemaResult schema(String namespace)` — returns a record containing `List<PreferenceSchemaDescriptor>` + `String version` (for ETag computation).

New record in preferences-editor-core:
```java
public record SchemaResult(List<PreferenceSchemaDescriptor> schemas, String version) {}
```

**Spring controller:** `PreferenceSchemaRestController` — computes `ETag` from `version`, checks `If-None-Match` header via Spring's `WebRequest.checkNotModified(etag)`, returns 304 or 200 with schemas.

**JAX-RS resource:** Becomes a thin wrapper using `Request.evaluatePreconditions(etag)`.

### 4. EngagementCallbackResource (notification-dispatch → notification-dispatch-core)

**Current:** 5 deps (`DeliveryAttemptStore`, `EngagementRecorder`, `CurrentPrincipal`, `Instance<EngagementCallbackHandler>`, `PreferenceProvider`), 2 endpoints, uses `Instance<>` and `@Context HttpHeaders`.

**Extraction:** Create `EngagementCallbackService` in notification-dispatch-core. Constructor takes:
- `DeliveryAttemptStore store`
- `EngagementRecorder recorder`
- `CurrentPrincipal principal`
- `Map<String, EngagementCallbackHandler> handlers` (not Instance<> — framework resolves)
- `PreferenceProvider preferenceProvider`

Methods:
- `void handleCallback(String channelId, String rawPayload, Map<String, String> headers)` — routes to handler, records engagement
- `void recordDirect(String attemptId, EngagementType type, String metadata)` — records direct engagement event

The `Instance<EngagementCallbackHandler>` → `Map` conversion happens in:
- Quarkus producer: iterates `Instance<>`, builds Map keyed by `channelId`
- Spring auto-config: collects `List<EngagementCallbackHandler>` beans via `ObjectProvider<>`, builds Map

**Spring controller:** `EngagementCallbackRestController` — `@PostMapping("/delivery/engagement/callback/{channelId}")` and `@PostMapping("/delivery/engagement/{attemptId}")`.

**JAX-RS resource:** Becomes a thin wrapper, extracts headers from `@Context HttpHeaders`.

### 5. CallbackDispatchResource (callback-client → new callback-client-core)

**Current:** 1 field-injected dep (`ObjectMapper`), programmatic `ConcurrentHashMap<String, Object>` registry, reflection-based method dispatch.

**Extraction:** Create new `callback-client-core` module. Extract `CallbackDispatcher` POJO. Constructor takes `ObjectMapper`. Methods:
- `void registerSpi(String spiName, Object bean)` — registers SPI implementation
- `Object dispatch(String spiName, String methodName, String spiHeader, byte[] argsJson)` — reflection-based dispatch, returns result or throws

The reflection logic (find method by name + param count, deserialize args, invoke) is already framework-neutral. The POJO owns the `ConcurrentHashMap` registry.

**Spring controller:** `CallbackDispatchRestController` — `@PostMapping("/casehub/callbacks/{spiName}/{methodName}")`, delegates to `CallbackDispatcher`.

**JAX-RS resource:** Becomes a thin wrapper delegating to `CallbackDispatcher`. `CallbackAutoRegistrar` (which calls `registerSpi()`) is updated to inject `CallbackDispatcher` instead of `CallbackDispatchResource` directly.

**New module pom.xml:** Dependencies: `platform-api`, `jackson-databind`. No CDI, no Spring.

### 6. WebhookResource (streams-webhook → new streams-webhook-core)

**Current:** 3 `@Inject` fields + 2 `@ConfigProperty` + `@Context HttpHeaders` + `@PostConstruct` + `Event<CloudEvent>.fireAsync()`.

**Extraction:** Create new `streams-webhook-core` module. Extract `WebhookReceiver` POJO. Constructor takes:
- `EndpointRegistry endpointRegistry`
- `CredentialResolver credentialResolver`
- `Consumer<CloudEvent> eventCallback` (replaces CDI Event<>)
- `String publicUrl`
- `boolean requireAuth`

Methods:
- `void init()` — registers endpoint descriptor (called by framework lifecycle)
- `WebhookResult receive(byte[] body, String tenancyId, String streamId, Map<String, String> headers)` — deserialize CloudEvent, validate credentials, enrich, fire via callback

New record:
```java
public record WebhookResult(boolean accepted, String errorMessage) {}
```

Framework wiring:
- Quarkus: `Consumer<CloudEvent> = cloudEventBus::fireAsync`, `@PostConstruct` calls `init()`
- Spring: `Consumer<CloudEvent> = publisher::publishEvent`, `@Bean(initMethod="init")` or `@PostConstruct`

**Spring controller:** `WebhookRestController` — `@PostMapping(value="/streams/webhook/{tenancyId}/{streamId}", consumes="application/cloudevents+json")`.

**New module pom.xml:** Dependencies: `platform-api`, `cloudevents-core`, `cloudevents-json-jackson`. No CDI, no Spring.

## New Modules

| Module | Artifact | Contents |
|--------|----------|----------|
| `callback-client-core` | `casehub-platform-callback-client-core` | `CallbackDispatcher` POJO |
| `streams-webhook-core` | `casehub-platform-streams-webhook-core` | `WebhookReceiver` POJO, `WebhookResult` record |

Both: Jandex plugin, zero CDI/Spring deps, pure Java.

## platform-spring Changes

New dependencies: `subscriptions-core`, `notification-dispatch-core`, `callback-client-core`, `streams-webhook-core`. (`preferences-editor-core` already present.)

New hand-written classes in `io.casehub.platform.spring.rest`:
- `EventTypeRestController`
- `SubscriptionRestController`
- `PreferenceSchemaRestController`
- `EngagementCallbackRestController`
- `CallbackDispatchRestController`
- `WebhookRestController`

## Execution Order

1. **Batch 1:** Create 2 new -core modules (callback-client-core, streams-webhook-core)
2. **Batch 2:** Extract POJOs into all 6 -core modules, refactor JAX-RS resources to thin wrappers
3. **Batch 3:** Write Spring @RestControllers in platform-spring, add dependencies
4. **Batch 4:** Tests — verify JAX-RS resources still pass existing tests, add unit tests for -core POJOs and Spring controllers

## Testing Strategy

- **Core POJOs:** Unit tests with constructor-injected mocks — no framework needed.
- **JAX-RS resources (existing tests):** Must continue passing after refactoring to thin wrappers.
- **Spring controllers:** Unit tests using `MockMvc` or direct invocation with mocked -core POJOs.

## References

- rest-spring-generator source — RestResourceScanner.java lines 62-77 (single-delegate limitation)
- GE-20260910-fc414e — Event<T> to Consumer<T> core extraction pattern
- GE-20260909-c81437 — module-core/module/module-spring naming convention
- GE-20260909-81809c — Jandex-based Spring auto-config generator technique
- GE-20260910-8ecdb7 — Core extraction breaks downstream test constructors
- casehubio/parent#483 — tracking issue
- specs/issue-469-dual-framework-core-extraction — original core extraction design
