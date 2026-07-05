# HANDOFF — casehub-platform

**Date:** 2026-07-05
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Designed and implemented notification subscription management (#142) + notification store minor findings (#149). First-principles brainstorming drove two key decisions: filters inline in subscriptions (not separate entities — same reasoning as Drools rules owning their LHS), and POJO-level filtering via DataSource alpha network (not CloudEvent transport layer). Adversarial design review (7 rounds, 25 issues — tenant isolation cross-leak in FilterNode sharing was the critical find). Three new modules: `subscriptions-inmem/`, `subscriptions-jpa/`, `subscriptions/` (engine + REST). MVEL3 mock phase for user constraints; type discrimination and tenant isolation use MethodHandle (MVEL-independent). Two garden entries: alpha network cross-tenant FilterNode leak (GE-20260705-002a78), UUIDv7 clock regression after wraparound (GE-20260705-fa70c8).

## Immediate Next Step

Pick from What's Next — #148 (target resolution, M/Med) is Phase 3 of epic #147. Domain module notification bridges (casehub-work, casehub-engine, casehub-iot) need filing as cross-repo issues to make subscriptions functional end-to-end.

## What's Left

**Epic #137 — DataSource SPI follow-up:**
- #138 Deregistration lifecycle — CDI event, router cleanup, subscription orphan handling · M · Med
- #139 Marshaller configuration model · S · Med
- #140 Engine DataSourceTrigger — cross-module engine integration · M · Med
- #141 MVEL3 real evaluator — blocked on Maven Central publish · S · Low

**Other:**
- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- Domain notification bridges (casehub-work, casehub-engine, casehub-iot) — not yet filed · S · Low each
- PLATFORM.md capability ownership update for subscription management — cross-repo (parent) · XS · Low

## What's Next

**Epic #147 — Notification system (implementation order):**

| Phase | # | Description | Scale | Complexity | Notes |
|-------|---|-------------|-------|------------|-------|
| ~~1~~ | ~~#135~~ | ~~In-app notification store~~ | ~~M~~ | ~~Med~~ | **done** |
| ~~2~~ | ~~#142~~ | ~~Subscription management~~ | ~~L~~ | ~~High~~ | **done** — landed as b50ea4b on main |
| 3 | #148 | Target resolution | M | Med | group → individual expansion |
| 4 | #143 | User channel preferences | S | Low | per-user delivery config |
| 5 | #145 | Mute and snooze | S | Med | temporary suppression |
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
| Subscription design spec | `docs/superpowers/specs/2026-07-05-notification-subscription-design.md` |
| Subscription plan | `docs/superpowers/plans/2026-07-05-notification-subscriptions.md` |
| Design review | `~/adr/casehub-platform/notification-subscription-*/tracker.md` |
| Notification store spec | `docs/superpowers/specs/2026-07-05-notification-store-design.md` |
| ARC42STORIES | `ARC42STORIES.MD` |
