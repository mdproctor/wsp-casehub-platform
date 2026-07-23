---
layout: post
title: "The Reactive Layer That Was Already Dead"
date: 2026-07-23
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [virtual-threads, reactive, jpa, sse]
---

Platform had two reactive SPIs — `ReactiveNotificationStore` and `ReactiveSubscriptionStore` — each with three implementations: NoOp `@DefaultBean`, InMemory `@Alternative`, and JPA native. Plus a `ReactiveAgentIdentityVerificationService` bridge in the identity module. Ten files, all implementing interfaces nobody consumed directly anymore.

The interesting part wasn't the deletion. It was what we found underneath.

## The JPA stores weren't what they claimed

The blocking `JpaNotificationStore` looked like a straightforward JPA implementation. It was actually a delegate — it injected `JpaReactiveNotificationStore` and wrapped every call in a Vert.x duplicated context to bridge reactive back to blocking. The "blocking" store was a reactive store wearing a trench coat.

This meant deleting the reactive store wasn't a matter of removing a parallel implementation. The blocking store had to be rewritten from scratch: `Panache.withTransaction()` chains replaced with `EntityManager` + `@Transactional`, `PanacheEntityBase` inheritance stripped from entities, the Vert.x context wrapper removed entirely. Same for subscriptions. Same for the retention scheduler, which injected `Mutiny.SessionFactory` for a `@Scheduled` purge — a reactive session factory for a job that runs on a Quarkus-managed timer thread.

The POMs told the same story. `notifications-jpa` depended on `quarkus-hibernate-reactive-panache` and `quarkus-reactive-pg-client`. Both replaced by `quarkus-hibernate-orm`.

## The SSE question nobody had answered

The REST resources were straightforward — `Uni<T>` return types became plain `T`, `@RunOnVirtualThread` at the class level, done. But `NotificationSseResource` stopped me.

SSE endpoints use `SseEventSink` with a `void` return. The connection stays open after the method returns. `@RunOnVirtualThread` is designed for short-lived request-response handlers. What happens when you combine them? Does the virtual thread get released when `stream()` returns, or does it stay pinned for the lifetime of the SSE connection?

Claude searched the Quarkus docs, GitHub discussions, and blog posts. Nothing. The interaction between `@RunOnVirtualThread` and SSE `SseEventSink` is genuinely undocumented. No guidance, no examples, no issues discussing it.

I decided not to guess. The SSE endpoint stays on the event loop. Blocking calls in the `stream()` method — the initial unread count fetch — are offloaded to `Executors.newVirtualThreadPerTaskExecutor()` explicitly. The `@ObservesAsync` CDI handlers already run on managed executor threads, so blocking calls there are safe without offloading.

We captured this as a protocol (`sse-endpoint-no-virtual-thread`) and updated the engine's migration guide. The rule is simple: `@RunOnVirtualThread` for request-response endpoints, explicit virtual executor offload for SSE setup, leave CDI async observers alone.

## What the migration guide missed

The engine's `virtual-thread-migration.md` cookbook covered SPIs, event handlers, persistence, bridges, configuration, and validation. It didn't cover SSE. The gap makes sense — the engine doesn't have SSE endpoints. Platform does. The guide now has a §7 addendum and a new entry in the common mistakes table.

The reactive tier in platform is gone. The code reads as though virtual threads were the original design — which is the whole point.
