---
layout: post
title: "The 167-Line Delete"
date: 2026-09-05
entry_type: note
subtype: diary
projects: [casehubio/platform]
tags: [notifications, websocket, push, quarkus, cdi]
series: issue-275-notif-sse-to-eventbroadcaster
---

# The 167-Line Delete

NotificationSseResource was the last SSE hold-out on the platform. The frontend
migrated to EventStreamController months ago, but the server was still managing
its own connection map — a ConcurrentHashMap of SseEventSink sets, keyed by
tenancy and user, swept every 60 seconds by a scheduled task. Three CDI observers
serialised notifications with ObjectMapper, iterated the connection set, and pushed
to each sink individually. 232 lines of connection lifecycle code to do what
EventBroadcaster does in one call.

The replacement is almost anticlimactic. NotificationPushService — renamed because
"SseResource" would have been a lie — injects EventBroadcaster and calls
`broadcast("notifications:" + userId + ":new", notification)`. The topic scheme
is colon-delimited and user-scoped: `:new`, `:updated`, `:unread-count`. Three
observers, three broadcast calls, one private helper for unread counts. 65 lines.
The connection map, the emitter record, the virtual executor, the scheduled sweep,
the SSE imports — all gone. The quarkus-scheduler dependency went with them.

The one genuinely interesting moment was Mockito. EventBroadcaster has two
`broadcast` overloads — `broadcast(String, String)` for raw JSON and a generic
`broadcast(String, T)` for typed payloads. When verifying with `any()`, Java
resolves to the String overload at compile time (null is assignable to String,
and most-specific-method wins). But the actual runtime call dispatches to the
generic overload after erasure. The result: Mockito says "wanted but not invoked"
while printing the exact interaction you expected — on a different method. The
fix is `any(Object.class)`, which forces the compiler to pick the generic
overload since Object is not assignable to String. Three test runs to figure that
out. It earned a garden entry.

The broader pattern is worth noting: every SSE resource we've migrated follows
the same arc. A hundred-plus lines of connection tracking, emitter lifecycle, and
serialisation boilerplate collapse into a handful of EventBroadcaster calls. The
infrastructure that used to live in every push endpoint now lives once, in
pages-push. The consuming code becomes a thin CDI bridge — observe the event,
call broadcast, done. That's the whole migration.
