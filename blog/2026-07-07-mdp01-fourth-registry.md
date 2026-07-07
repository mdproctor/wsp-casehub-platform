---
layout: post
title: "The Fourth Registry"
date: 2026-07-07
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [notification, subscription, spi]
---

Platform already has three registries following the same pattern: `DataSourceRegistry`, `EndpointRegistry`, `DeliveryChannelRegistry`. Each owns a `register`/`resolve`/`discover` contract backed by a `@DefaultBean` no-op and a `ConcurrentHashMap` in-memory implementation. `EventTypeRegistry` is the fourth — discoverable event type metadata for the subscription system.

The gap was obvious once we had the subscription engine running. Users can subscribe to event types with constraints and targets, but there's no API to discover what event types exist, what fields they expose, or what values are valid. The subscription UI (#146) has nothing to populate its dropdowns with. Domain bridges know exactly which event types they produce — they just had nowhere to register that knowledge.

The design follows the existing registry pattern exactly. `EventTypeDescriptor` and `EventFieldDescriptor` are records in `platform-api`. The SPI is three methods: `register`, `resolve`, `discover`. `NoOpEventTypeRegistry` is a `@DefaultBean` in `platform/` that returns empty from everything — and critically, fires no CDI events. The in-memory implementation and `GET /subscriptions/event-types` REST endpoint live in the `subscriptions/` module. Domain bridges will call `register()` from `@PostConstruct` at startup, the same way deliverers self-register their channels.

We also added `WeeklyAt` to `DigestSchedule` — the third sealed variant alongside `Interval` and `DailyAt`. Same `isFlushDue(oldestPending, lastFlush, now)` contract, same polymorphic dispatch in `DigestFlushScheduler`. The logic finds the most recent occurrence of the target day-of-week and time in the user's timezone, then checks whether `now` has passed it and `lastFlush` hasn't. Monday 9:00 UTC means: has Monday 9:00 happened this week, and did we already flush since then?

Both additions are deliberate groundwork. The event type registry makes the subscription system self-describing — without it, every consumer has to hardcode event type strings and field names. `WeeklyAt` fills the obvious gap in digest scheduling before anyone has to ask for it.
