# Migrate NotificationSseResource from SseEventSink to EventBroadcaster

**Issue:** casehubio/platform#275
**Date:** 2026-09-05
**Status:** Approved

## Summary

Replace the SSE-based push mechanism in `NotificationPushService` with
`EventBroadcaster` from `casehub-pages-push`. The frontend has migrated
from SSEManager to EventStreamController/PushMixin (blocks-ui#153,
casehub-pages#409), which expects events on the WebSocket push channel.

This is a wiring change — the CDI event observation stays, the delivery
transport changes from server-managed SSE connections to
`EventBroadcaster.broadcast()`.

## Architecture

### Before

`NotificationPushService` is a `@Path("/notifications/stream")`
JAX-RS endpoint that:

1. Accepts SSE connections via `GET /notifications/stream`
2. Tracks connections in `ConcurrentHashMap<String, Set<EmitterWithContext>>`
   keyed by `tenancyId::userId`
3. Observes three CDI events (`NotificationCreated`,
   `NotificationStatusChanged`, `AllNotificationsRead`) via `@ObservesAsync`
4. Iterates connected emitters and calls `SseEventSink.send()` with
   serialized events
5. Sweeps stale emitters on a 60s `@Scheduled` timer
6. Sends an initial unread count on connection establishment

### After

`NotificationPushService` (renamed via IntelliJ refactoring) is an
`@ApplicationScoped` CDI bean that:

1. Injects `EventBroadcaster` from `casehub-pages-push`
2. Observes the same three CDI events via `@ObservesAsync`
3. Calls `eventBroadcaster.broadcast(topic, payload)` with user-scoped
   topics — no connection tracking, no emitter management

All SSE infrastructure is removed. Connection management, topic routing,
and WebSocket delivery are handled by the pages-push runtime
(`TopicRegistry`, `SessionSender`, `EventStore`).

## Topic Scheme

| CDI Event | Topic | Payload |
|-----------|-------|---------|
| `NotificationCreated` | `notifications:{userId}:new` | `Notification` object (serialized by `JsonWriter`) |
| `NotificationStatusChanged` | `notifications:{userId}:updated` | `Notification` object (serialized by `JsonWriter`) |
| `NotificationCreated` | `notifications:{userId}:unread-count` | `UnreadCount` record |
| `NotificationStatusChanged` | `notifications:{userId}:unread-count` | `UnreadCount` record |
| `AllNotificationsRead` | `notifications:{userId}:unread-count` | `UnreadCount` record |

All three event types trigger an unread count broadcast after their
primary broadcast (if any). `AllNotificationsRead` only broadcasts
the unread count — there is no notification payload to push.

## Removals

| Item | Why |
|------|-----|
| `@Path("/notifications/stream")` + `stream()` endpoint | SSE endpoint replaced by WebSocket subscription |
| `ConcurrentHashMap<String, Set<EmitterWithContext>>` | Connection tracking handled by `TopicRegistry` |
| `EmitterWithContext` record | No longer needed |
| `VIRTUAL_EXECUTOR` static field | Initial unread count on connect eliminated |
| `@Scheduled sweepStaleEmitters()` | Emitter lifecycle handled by pages-push |
| `sendUnreadCount()` / `sendUnreadCountToUser()` | Replaced by `broadcastUnreadCount()` |
| `removeEmitter()` | No emitters to manage |
| `jakarta.ws.rs.sse.*` imports | SSE API no longer used |
| `jakarta.ws.rs.core.Context` import | No JAX-RS context injection |
| `jakarta.ws.rs.GET` / `Produces` / `Path` imports | No JAX-RS endpoint |
| `ObjectMapper` injection | Serialization delegated to `EventBroadcaster.broadcast(topic, T)` |
| `CurrentPrincipal` injection | Only used in `stream()` endpoint — observers get userId/tenancyId from event payloads |

## Additions

| Item | Detail |
|------|--------|
| `casehub-pages-push` compile dependency | In `notifications/pom.xml` |
| `@Inject EventBroadcaster` field | Replaces all SSE send infrastructure |
| `broadcastUnreadCount(userId, tenancyId)` | Private helper — queries `NotificationStore.unreadCount()` via `SessionIsolator`, broadcasts to `notifications:{userId}:unread-count` |
| `UnreadCount` record | Private record: `record UnreadCount(long count) {}` — typed payload for the unread-count topic |

## Initial Unread Count

The SSE endpoint sent an initial unread count when a client connected.
With EventBroadcaster there is no server-side connection callback — the
pages-push protocol is topic-subscription-based, not connection-based.

Clients get the initial unread count via the existing REST API
(`GET /notifications` with unread count in response metadata, or the
unread-count query). No new code is needed — the existing REST endpoint
already serves this.

## Testing

No SSE test exists for `NotificationPushService` today. The new
`NotificationPushService` is testable by:

1. Injecting a mock `EventBroadcaster` (or using `@InjectMock` in a
   `@QuarkusTest`)
2. Firing CDI events programmatically
3. Verifying `broadcast()` calls with expected topics and payloads

Test coverage:
- `onNotificationCreated` → broadcasts to `:new` and `:unread-count` topics
- `onNotificationStatusChanged` → broadcasts to `:updated` and `:unread-count` topics
- `onAllNotificationsRead` → broadcasts to `:unread-count` topic only
- Unread count query failure → logs error, does not propagate

## Dependency Impact

`casehub-pages-push` is a lightweight module (5 classes:
`EventBroadcaster`, `TopicRegistry`, `SessionSender`, `EventStore`,
`JsonWriter`). It is already on the platform classpath per issue #275.
Adding it as a compile dependency to the notifications module makes the
usage explicit.

## References

- `NotificationSseResource.java` (notifications module) — current implementation
- `EventBroadcaster.class` (casehub-pages-push jar) — target API
- casehubio/platform#275 — issue with topic scheme and reference implementations
- SocTrustPushService, SocIncidentPushService (engine/soc) — reference pattern
- helpdesk TicketPushObserver (example app) — CDI event → EventBroadcaster bridge pattern
