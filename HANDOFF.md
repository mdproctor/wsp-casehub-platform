# HANDOFF — casehub-platform

**Date:** 2026-07-05
**Project:** `/Users/mdproctor/claude/casehub/platform`
**Workspace:** `/Users/mdproctor/claude/public/casehub/platform`

---

## Last Session

Designed and implemented the notification store (#135) — Phase 1 of epic #147. Brainstormed with typed records over maps for type safety propagation, adversarial design review (19 issues, all resolved), implemented via subagent-driven development (6 tasks). Three new modules: `notifications-inmem/`, `notifications-jpa/`, `notifications/`. Both blocking and reactive SPIs implemented natively by every backend — no bridges. Discovered H2 reactive emulation fails with Hibernate Reactive Panache on Instant fields (GE-20260705-2aa4c8). Filed neocortex#101 for bridge-only reactive impls.

## Immediate Next Step

Pick from What's Next — #142 (subscription management, L/High) is Phase 2 of epic #147 and the next logical step. Requires DataSource deregistration (#138) for subscription CRUD. Alternatively, pick from the non-notification backlog.

## What's Left

**Epic #137 — DataSource SPI follow-up:**
- #138 Deregistration lifecycle — CDI event, router cleanup, subscription orphan handling · M · Med
- #139 Marshaller configuration model — wiring mechanism for `Marshaller<I,O>` · S · Med
- #140 Engine `DataSourceTrigger` — external event reactivity (cross-module: engine) · M · Med
- #141 MVEL3 real evaluator — blocked on Maven Central publish · S · Low

**Other:**
- #149 Minor findings from #135 code review — UUIDv7 wraparound, Thread.sleep in tests, SSE sweep, cursor encoding, spec stale section · XS · Low
- casehubio/neocortex#101 — bridge-only reactive implementations · M · Med
- casehubio/ledger#161 — update DIDResolver callers for actorId parameter · S · Low
- casehubio/ledger#165 — IdentityCacheInvalidator: use invalidate() instead of instanceof · XS · Low

## What's Next

**Epic #147 — Notification system (implementation order):**

| Phase | # | Description | Scale | Complexity | Notes |
|-------|---|-------------|-------|------------|-------|
| ~~1~~ | ~~#135~~ | ~~In-app notification store~~ | ~~M~~ | ~~Med~~ | **done** — landed as 0682213 on main |
| 2 | #142 | Subscription management | L | High | core orchestration, DataSource alpha network integration |
| 3 | #148 | Target resolution (user/role/team/channel) | M | Med | expands group targets to individual users |
| 4 | #143 | User channel preferences | S | Low | per-user delivery config |
| 5 | #145 | Mute and snooze | S | Med | temporary suppression |
| 6 | #144 | Digest and batching | M | High | timer-driven aggregation |
| 7 | #146 | Notification center (frontend) | L | Med | can start after #135 API stable |

**Other:**

| # | Description | Scale | Complexity | Notes |
|---|-------------|-------|------------|-------|
| #131 | did:key base58btc encoding (W3C spec compliance) | M | Med | no interop impact until external DIDs |
| #133 | secp256k1 did:key support | M | High | requires BouncyCastle or manual curve params |
| #134 | shared embedding similarity utility | S | Low | consolidate cosine similarity from engine and work |

## References

| Type | Path |
|------|------|
| Design spec | `docs/superpowers/specs/2026-07-05-notification-store-design.md` |
| Implementation plan | `docs/superpowers/plans/2026-07-05-notification-store.md` |
| Design review | `~/adr/casehub-platform/notification-store-*/tracker.md` |
| ARC42STORIES | `ARC42STORIES.MD` |
