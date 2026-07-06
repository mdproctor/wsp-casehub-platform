---
layout: post
title: "Digest and Batching — Making External Channels Bearable"
date: 2026-07-06
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [notifications, digest, sealed-interface, scheduling]
---

The notification pipeline has been delivering every matched event immediately to every channel since it shipped. That's fine for in-app — real-time is the point. But for email? A user subscribed to "all comments on my work items" getting 50 individual emails during a heated discussion thread is not a feature, it's harassment.

Digest batching sits between matching and delivery. When a subscription fires, in-app still delivers immediately. External channels — email, SMS, push — can buffer notifications and flush them as a periodic summary: "12 new comments on 3 work items" instead of 12 separate emails.

## Where to intercept

The pipeline runs: subscription match → target resolution → suppression → template resolution → channel routing → delivery. The question was where digest belongs.

I traced the data available at each stage. Before template resolution, the raw event POJO is still in play — it's a transient in-memory object, non-serializable, resolved via MethodHandle. You can't buffer it. After template resolution, the `NotificationInput` is a pure record: userId, tenancyId, title, body, severity, source. Fully resolved, no runtime dependencies, trivially storable.

After channel routing, we also know which channels this notification targets and whether each is external. That's the interception point: `NotificationInput` is complete, channels are known, and mute has already filtered. The dispatcher's delivery loop becomes three paths — digest, suppress, or deliver immediately.

## The schedule model

I wanted the flush-due check to be polymorphic on the schedule type — adding a weekly variant later should require zero scheduler changes. A sealed interface with `isFlushDue(Instant oldestPending, Instant lastFlush, Instant now)` does this cleanly:

```java
public sealed interface DigestSchedule {
    boolean isFlushDue(Instant oldestPending, Instant lastFlush, Instant now);

    record Interval(Duration period) implements DigestSchedule { /* ... */ }
    record DailyAt(LocalTime time, ZoneId timezone) implements DigestSchedule { /* ... */ }
}
```

`Interval` measures accumulation time — how long the oldest buffered item has been waiting. `DailyAt` checks whether the wall-clock target has passed since the last flush. The scheduler calls `schedule.isFlushDue()` and doesn't care which variant it got.

## Suppression at flush time

The existing `SuppressionEvaluator` couldn't be reused directly at flush time. Its `evaluate()` method requires entity-level parameters — `entityType`, `entityId`, `category` — that don't exist for a heterogeneous digest batch containing notifications about different entities. The design review caught this: we needed a `evaluateUserLevel()` method that checks only snooze and quiet hours (user-scoped concerns), always returning `isMuted = false`. Entity-level mute was already evaluated at buffer time.

## What the review caught

The adversarial review ran three rounds and raised 13 issues. The ones that shaped the final design: the `isFlushDue()` polymorphism itself (the original spec had the scheduler doing `if/else` on the schedule type — the reviewer rightly said that defeats the sealed interface); a non-empty invariant on `DigestSummary` (the default `deliverDigest()` calls `getFirst()` — empty list would blow up); per-key error isolation in the scheduler tick loop (one broken delivery shouldn't block every other user's digest); and `CopyOnWriteArrayList` inside `ConcurrentHashMap.compute()` being O(n) per eviction — wasteful when `compute()` already serializes per-key access and a plain `ArrayList` is correct.

The Jackson `isDigested()` gotcha was a surprise. Adding a `boolean isX()` convenience method to a Jackson-serialized record silently serializes a phantom `"digested"` property — JavaBeans introspection treats it as a readable property. JPA round-trips fail because deserialization finds a field with no matching constructor parameter. `@JsonIgnore` fixes it, but it's the kind of thing that only surfaces when you actually persist the record through a JSON column.

## What's next

The pipeline works end-to-end for in-app + buffered external channels. The deferred pieces: persistent buffer storage for deployments that can't tolerate restart loss, weekly schedule variant, user-configurable grouping within digests, and the quiet-hours integration that would buffer suppressed notifications into the next digest instead of dropping them entirely.
