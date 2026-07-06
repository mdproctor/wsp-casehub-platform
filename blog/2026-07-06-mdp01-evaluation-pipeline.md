---
layout: post
title: "The evaluation pipeline: who gets told, who doesn't"
date: 2026-07-06
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [notifications, architecture, pipeline]
---

When I started the subscription system a few days ago, I left a design flaw in place knowingly. The `userId` field on a subscription was both the person who created it and the person who received notifications. For personal subscriptions that's fine — you create a subscription, you get the notifications. But target resolution breaks that model entirely.

Target resolution is about expanding abstract recipients — "notify everyone on the ops team" — into concrete user lists. The moment a subscription can target a group, the owner and the recipient are different people. I could have added an optional `targets` field and kept `userId` as a fallback, but that's a workaround. The right design is explicit targets on every subscription. `userId` becomes `ownerId`, and every subscription declares who it's notifying. The REST layer still defaults to "notify the owner" when no targets are specified — convenience for the common case, but the SPI doesn't pretend.

The bigger architectural shift was extracting the delivery pipeline from the SubscriptionEngine. Previously the engine did everything: match the event in the alpha network, resolve the template, store the notification. That was fine when delivery meant "write one row." With target resolution, suppression rules, and channel routing in the mix, the engine would have become a god class. We split it at the CDI event boundary — the engine fires `SubscriptionMatched` via `fireAsync`, and a separate `NotificationDispatcher` observes it on the managed executor pool. The alpha network never blocks on SCIM calls or channel delivery failures.

The dispatcher itself is a pipeline of three stage beans. `TargetResolver` expands groups and handles actor self-exclusion. `SuppressionEvaluator` checks mute rules and snooze — this one is a pure function over pre-fetched data, no injected dependencies, independently testable. `ChannelRouter` resolves which delivery channels each user gets based on their preferences and the current suppression state.

I pushed back on my own instinct at one point during the design. Claude proposed a `DeliveryChannelRegistry` for managing delivery channels, and I initially dismissed it as overengineered — "just use string constants." But the codebase already has `DataSourceRegistry` and `EndpointRegistry` following the exact same pattern. Consistency within a system makes it predictable. A third registry isn't a new abstraction — it's the expected shape. I was wrong.

Mute and snooze look similar on the surface but have different pipeline semantics. A muted notification is dropped entirely — no in-app record, nothing. A snoozed notification still writes to the in-app store but suppresses external channels. They're not "the same thing with different durations" — one is a filter, the other is a delivery modifier. We unified them in a single `SuppressionStore` SPI since they're both per-user suppression state queried at the same pipeline step, but they affect the pipeline differently.

The design review caught things I wouldn't have. The pipeline originally ran template resolution before suppression checks — wasted work for every muted user. The channel defaults were hardcoded in the router instead of self-declared by each deliverer. The Flyway backfill for existing subscriptions was missing entirely, which would have caused silent delivery failure after migration. Twenty-one issues across five rounds, all resolved.

One finding from the final code review was wrong, and proving it was instructive. Claude flagged `entityManager.flush()` and `entityManager.clear()` after a bulk JPQL DELETE as unnecessary. Removing them caused an immediate test failure — Hibernate's first-level cache still held the deleted entity, so a subsequent `find()` returned stale data. Bulk JPQL operations bypass the L1 cache. The flush-and-clear was doing exactly what it needed to do.
