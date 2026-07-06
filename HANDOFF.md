# HANDOFF — casehub-platform

**Date:** 2026-07-06
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Designed and implemented notification target resolution (#148), user channel preferences (#143), and mute/snooze (#145) — phases 3, 4, 5 of epic #147. Subscription model fixed: userId→ownerId with explicit `List<NotificationTarget>` on every subscription. Delivery pipeline extracted from SubscriptionEngine into NotificationDispatcher (async via CDI fireAsync). Three new modules: notification-settings-inmem/, notification-settings-jpa/, notification-dispatch/. DeliveryChannelRegistry follows DataSourceRegistry/EndpointRegistry pattern. SuppressionEvaluator is a pure function — no injected dependencies. Design review: 5 rounds, 21 issues, all resolved. Four deferred issues filed: #154 (guaranteed delivery), #155 (EventTypeRegistry), #156 (channel subscriber target), #157 (minor findings).

## Immediate Next Step

Pick from What's Next — domain notification bridges (casehub-work, casehub-engine, casehub-iot) need filing as cross-repo issues to make the pipeline functional end-to-end. Alternatively, #144 (digest/batching) is the next pipeline stage.

## What's Left

**Epic #137 — DataSource SPI follow-up:**
- #138 Deregistration lifecycle — CDI event, router cleanup, subscription orphan handling · M · Med
- #139 Marshaller configuration model · S · Med
- #140 Engine DataSourceTrigger — cross-module engine integration · M · Med
- #141 MVEL3 real evaluator — blocked on Maven Central publish · S · Low

**Other:**
- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- Domain notification bridges (casehub-work, casehub-engine, casehub-iot) — not yet filed · S · Low each
- PLATFORM.md capability ownership update for notification pipeline — cross-repo (parent) · XS · Low
- #154 Guaranteed delivery + tracking · M · Med
- #155 EventTypeRegistry · S · Low
- #156 Channel subscriber target type · S · Med
- #157 Minor findings from code review · S · Low

## What's Next

**Epic #147 — Notification system (remaining phases):**

| Phase | # | Description | Scale | Complexity | Notes |
|-------|---|-------------|-------|------------|-------|
| ~~1~~ | ~~#135~~ | ~~In-app notification store~~ | ~~M~~ | ~~Med~~ | **done** |
| ~~2~~ | ~~#142~~ | ~~Subscription management~~ | ~~L~~ | ~~High~~ | **done** |
| ~~3~~ | ~~#148~~ | ~~Target resolution~~ | ~~M~~ | ~~Med~~ | **done** — landed as 840095d on main |
| ~~4~~ | ~~#143~~ | ~~User channel preferences~~ | ~~S~~ | ~~Low~~ | **done** — landed as 840095d on main |
| ~~5~~ | ~~#145~~ | ~~Mute and snooze~~ | ~~S~~ | ~~Med~~ | **done** — landed as 840095d on main |
| 6 | #144 | Digest and batching | M | High | timer-driven aggregation |
| 7 | #146 | Notification center (frontend) | L | Med | after #135 API stable |

**Other:**

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #131 | did:key base58btc encoding | M | Med | no interop impact yet |
| #133 | secp256k1 did:key support | M | High | requires BouncyCastle |
| #134 | shared embedding similarity | S | Low | consolidate from engine+work |

## References

| Type | Path |
|------|------|
| Design spec | `docs/superpowers/specs/2026-07-06-notification-target-mute-prefs-design.md` |
| Design review | `~/adr/casehub-platform/notification-target-mute-prefs-20260706-005946/tracker.md` |
| Plan | `plans/attic/issue-148-notification-target-mute-prefs/` |
| ARC42STORIES | `ARC42STORIES.MD` |
