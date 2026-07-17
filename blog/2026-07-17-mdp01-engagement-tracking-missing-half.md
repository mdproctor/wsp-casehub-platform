---
layout: post
title: "Engagement tracking: the missing half of delivery"
date: 2026-07-17
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [notification, delivery, engagement, spi]
series: issue-170-delivery-engagement-tracking
---

Delivery tracking tells you whether a notification reached the channel. It says nothing about whether anyone read it. That gap — between "delivered" and "engaged" — is what #170 closes.

The core model is five `EngagementType` values: OPENED, CLICKED, DISMISSED, REPLIED, CONVERTED. Channel implementations map provider-specific signals to these — email tracking pixel becomes OPENED, push notification tap becomes OPENED, email link click becomes CLICKED. The platform defines the vocabulary; providers map to it.

We put engagement events on `DeliveryAttempt` rather than creating a separate store. The reasoning: engagement is an attribute of a delivery, not an independent entity. A separate `EngagementStore` would force cross-store joins for the most common question — "was this notification opened?" Summary fields (`firstOpenedAt`, `firstClickedAt`) sit directly on the attempt record for fast queries. Individual `EngagementEvent` records carry the full history.

The callback infrastructure has three paths, all converging on a single `EngagementRecorder`. A generic REST endpoint at `/delivery/engagement/callback/{channelId}` delegates to an `EngagementCallbackHandler` SPI — channel modules register handlers that translate provider webhooks (SendGrid JSON, Twilio form-encoded) into `RawEngagement` records. A direct path at `/delivery/engagement/{attemptId}` accepts a bare `EngagementType` and metadata for systems that already know the attempt ID. And any module can call `recordEngagement()` programmatically.

The interesting design question was in-app. In-app notifications already have `Notification.readAt` — why duplicate into the engagement system? Because they answer different questions. `readAt` is notification-level UI state: it drives the unread badge. An `EngagementEvent(OPENED)` on the in-app delivery attempt is delivery-level analytics: it answers "did the user engage via this channel?" Without the bridge, cross-channel engagement queries show 0% for the most-used channel. The bridge itself is clean — `@ObservesAsync NotificationStatusChanged` already fires when `markRead` is called; the observer maps READ to OPENED and DISMISSED to DISMISSED, looks up the in-app delivery attempt, and records via the same `EngagementRecorder`.

One known limitation worth flagging: `markAllRead()` doesn't fire per-notification status events in any current store implementation. Both `InMemoryNotificationStore` and `JpaReactiveNotificationStore` fire only the bulk `AllNotificationsRead` event. The bridge underreports OPENED for bulk-read operations — acceptable because mark-all-read is housekeeping, not engagement.

The whole system is gated by `casehub.delivery.engagement.enabled`, defaulting to `false`. The opt-in gate lives at the recorder level, not the store — modules that manage their own consent can call `recordEngagement()` directly. The design review caught this requirement from #154's acceptance criteria before we'd thought to address it.
