---
layout: post
title: "The commit that fell between the cracks"
date: 2026-07-20
type: phase-update
entry_type: note
subtype: diary
projects: [casehub-platform]
tags: [git-workflow, notification-architecture, cross-repo]
---

## The commit that fell between the cracks

A cross-repo review from Ras flagged a missing interface — `StringExpressionEvaluator`, a sub-interface of `ExpressionEvaluator` for string-based evaluators. It was supposed to be on main. It wasn't.

Claude traced it to branch `issue-176-expression-spi-and-cloudevent`. The branch had been stamped closed — `chore: branch closed — landed as da5065d on main`. That stamp says "everything here reached main." Except the `StringExpressionEvaluator` commit was added to the branch *after* the squash had already landed. The stamp went on top, and nobody noticed the late commit sitting underneath it.

The fix was a cherry-pick — clean, no conflicts, 36 insertions across 4 files. But the failure mode is worth naming: a branch-closed stamp doesn't validate that all commits are ancestors of the landing SHA. It's a declaration, not a proof.

## Three buckets, not two

The handover skill's Cross-Module section had two categories: "We're blocking" and "Blocked by." The first one was wrong — "we're blocking" reads as "we are preventing progress," which was the opposite of the intent. Most items listed were things platform had already delivered.

I split it into three:

- **Blocking** — we owe something another repo needs. We're the bottleneck.
- **Enabled** — we delivered our part, downstream work is now unblocked. Track so we chase it.
- **Blocked by** — our work is gated on someone else shipping.

Each has a different action: do it, track it, wait. No overlap.

## The notification wiring gap

Devtown asked for a `ConnectorNotificationDeliverer` in platform — a bridge from `NotificationDeliverer` to casehub-connectors' `Connector.send()`. That can't live in platform; platform has no casehubio dependencies and publishes first in the build order.

But the request surfaced something real. Platform's notification system defines four delivery channels — `IN_APP`, `EMAIL`, `SMS`, `PUSH` — and the only one with an actual deliverer is `InAppNotificationDeliverer`. The rest are constants with nothing behind them.

The connectors repo already has the outbound SPI: `Connector.id()` + `send(ConnectorMessage)`, CDI auto-discovered, with built-in Slack, Teams, Twilio SMS, WhatsApp, and email. The bridge belongs in connectors — at startup, iterate all `Connector` beans, wrap each in a `NotificationDeliverer`, register with `DeliveryChannelRegistry`. New connectors automatically become notification channels.

One design gap remains: `ConnectorMessage` needs a `destination` (webhook URL, phone number, email address), but `NotificationInput` has a `userId`. That resolution step — user to connector-specific destination — is the piece that needs designing.

Meanwhile, casehub-work has its own parallel notification system: `NotificationDispatcher`, `NotificationChannel` SPI, hardcoded `SlackNotificationChannel` and `TeamsNotificationChannel` that directly inject connectors. Qhorus has a `NotificationBridgeObserver` that calls `NotificationStore.store()` directly, bypassing the subscription engine. IoT has a stub. All three need migrating to platform's subscription engine — filed as work#315, qhorus#375, and iot#67. The connector bridge is connectors#86.
