---
layout: post
title: "Subscription Management: From CloudEvents to POJOs"
date: 2026-07-05
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [notifications, subscriptions, alpha-network, datasource, design-review]
---

# Subscription Management: From CloudEvents to POJOs

The notification store landed this morning. By afternoon I was deep into the subscription engine — the piece that turns "notify me when X happens" into actual notifications flowing through the store.

## The Wrong Abstraction

I started at the CloudEvent level. The platform already has a CloudEvent pipeline: domain events serialise to JSON, wrap in a CloudEvent envelope, flow through DataSourceRouter to DataSources. Subscribe to CloudEvents, filter on their fields, done.

Except CloudEvents are a transport artifact. When a WorkItem completes, the origin is `WorkItemLifecycleEvent` — a typed POJO with `priority()`, `assigneeId()`, `status()`. The CloudEvent pathway serialises that POJO to JSON bytes, wraps it in an envelope, fires it over CDI. DataSourceRouter picks it up, routes it to DataSources. The alpha network evaluates. Everything works, but the subscription engine would be deserialising JSON just to access fields that were live Java objects two hops earlier.

The chain from origin:

```
WorkItemService.complete()
  → emitter.emit(WorkItemLifecycleEvent)
    → CDI fireAsync(POJO)              ← live here
      ├→ CloudEvent adapter            ← serialises for Kafka/AMQP
      └→ notification bridge (new)     ← pushes POJO into DataSource
```

The POJO is right there at `fireAsync()`. Everything downstream is transport infrastructure for external consumers. The subscription engine is an internal consumer — it has no business working with the serialised form.

## Single DataSource, Alpha Network Does the Rest

The design uses one platform-global DataSource for all notification-eligible events. Domain modules each add a small bridge (~5 lines) that pushes lifecycle POJOs into it. The alpha network's TypeNode discriminates by event type string, FilterNodes evaluate user constraints on the live POJO fields. Adding a new event source means adding a bridge in the domain module — nothing changes in the subscription engine.

This is the alpha network pattern from Drools applied directly. One root, type discrimination fans out to per-type subtrees, filter evaluation within each type. The subscription engine doesn't implement matching — it wires subscriptions as alpha network subscribers and lets the DataSource handle evaluation.

## The Tenant Isolation Trap

The design review caught the most important issue: FilterNode sharing across tenants.

The alpha network shares FilterNodes when two subscriptions have the same `FilterExpression.type()` and `FilterExpression.expression()`. Two subscriptions from different tenants — both filtering on `priority == HIGH` — produce identical expression strings. They share a single FilterNode. That FilterNode evaluates one predicate and fans out to all subscribers. When tenant-A's event passes, tenant-B's subscriber fires.

The fix: embed the tenant ID in the expression string — `"tenant=tenant-1:priority == HIGH"`. This makes `filtersMatch()` return false across tenants. Within the same tenant, identical expressions still share nodes — the optimisation works where it should and fails where it must. A native Java tenancy check via MethodHandle in the predicate provides defense-in-depth.

I wouldn't have caught this without an adversarial review. The sharing is an internal alpha network optimisation — invisible at the subscription API level. You'd only discover it when tenant-B starts receiving tenant-A's notifications in production.

## What's Deferred

MVEL3 isn't on Maven Central yet, so user constraint predicates are mocked (always return true). Type discrimination and tenant isolation use MethodHandle — they work independently of MVEL. When MVEL3 publishes, constraints compile to real predicates. No SPI change needed.

System subscriptions (admin-defined, applies to all users in a role/group), external delivery (Slack, email via connectors), and event type glob matching are all filed as issues under the notification epic. The subscription model supports adding them without breaking the SPI — `String eventType` accepts patterns, the engine just needs to evaluate them differently.
