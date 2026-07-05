---
layout: post
title: "Notification Store: Type Safety All the Way Down"
date: 2026-07-05
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [notification, spi, reactive, sse, type-safety]
series: issue-135-notification-store
---

The notification store is the first new store SPI in `platform-api` since CaseMemoryStore moved to neocortex. It's the terminal sink in the notification pipeline — the routing layer evaluates subscriptions against incoming events, resolves targets, and writes notification records here. Users read them via REST; SSE pushes updates in real time.

The interesting design question wasn't the store itself — that follows the established Store SPI pattern. It was the data model, and specifically what `sourceEvent` should look like. The original issue described it as `JSONB/Map` — a bag of event context. I wanted typed records instead.

Every notification carries a reference back to its originating event: the CloudEvent ID, the entity type and ID, and the actor who performed the action. That's a fixed structure. Every notification has it. It never varies by event type. A `Map<String, String>` here is a type safety regression — it forces every consumer to know key names, handle nulls, and parse values at runtime. The platform uses maps for genuinely heterogeneous property bags like endpoint configuration, where each protocol has different keys. Source references aren't heterogeneous. They're a typed record: `NotificationSource(eventId, entityType, entityId, actorId)`.

The same thinking drove the `NotificationInput` / `Notification` split. The routing layer constructs a `NotificationInput` — no ID, no status, no timestamps. The store generates those and returns a `Notification`. The store owns identity and lifecycle. The caller can't set an ID to a wrong value because it never has the field. This follows the `MemoryInput` / `Memory` precedent, and it's the right contract: you give me the content, I give you the persistent record.

The reactive SPI nearly went wrong. I initially recommended blocking only — "add the reactive mirror when a consumer needs it." Claude pushed back correctly: the protocol mandates dual variants when the store is consumed from both contexts. But the real problem wasn't my recommendation — it was what I found when I checked the existing reactive SPIs. `ReactiveCaseMemoryStore` in neocortex has exactly one implementation: a `BlockingToReactiveBridge` that wraps blocking calls in `Uni.createFrom().item().runSubscriptionOn(workerPool)`. No backend implements the reactive SPI natively. The reactive contract exists but is never fulfilled reactively. The engine's `ReactivePlanItemStore` does it right — `JpaReactivePlanItemStore` uses Hibernate Reactive Panache natively. Neocortex doesn't.

For the notification store, both SPIs are peer contracts. The in-memory backend implements both natively — ConcurrentHashMap is non-blocking, so the reactive variant runs on the caller's thread without `runSubscriptionOn`. The JPA backend uses Hibernate Reactive Panache for the reactive SPI and runs the reactive operations on a Vert.x context for the blocking SPI. No bridges anywhere.

We chose SSE over WebSocket for the push channel. Notification push is unidirectional — server to client. SSE gives us that natively with auto-reconnection built into the browser's `EventSource` API. WebSocket would add connection lifecycle management, heartbeat pings, and manual reconnection logic for a bidirectional channel we'd only use in one direction.

One genuine gotcha from implementation: H2's reactive emulation — the `quarkiverse/quarkus-reactive-h2-client` — silently returns null for `Instant`/`TIMESTAMP` fields when used with Hibernate Reactive Panache. Entities persist fine; the NullPointerException hits on fetch. The claudony app uses the same artifact without issues because its reactive-tested entities don't have temporal fields. The fix is PostgreSQL DevServices for any reactive Panache module with timestamps.

The notification store is Phase 1 of a larger notification epic. The routing layer, target resolution, preferences, mute/snooze, and digest batching are all separate issues that build on this store. The SPI is the foundation — everything else writes to it or reads from it.
